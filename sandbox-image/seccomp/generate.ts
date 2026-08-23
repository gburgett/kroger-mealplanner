// Generates the cBPF seccomp filter that bubblewrap loads with
// --add-seccomp-fd. See ADR 0008.
//
// Run it:  node sandbox-image/seccomp/generate.ts sandbox-image/seccomp/filter.bpf
//
// The output is a raw array of `struct sock_filter` (8 bytes each), which is
// exactly what bubblewrap reads from the file descriptor. The generator is
// committed beside the filter so the bytes can be regenerated and compared;
// `sandbox-image/build.sh` does that on every build.
//
// Why a filter at all, when the sandbox already has no network namespace and no
// network client: because a containment control must not depend on one thing
// being right. `gawk` opens /inet/tcp/... sockets, and the seccomp denial of
// `socket` stops it without reference to the namespace. Either control is
// sufficient alone, which is the point.

// ---------------------------------------------------------------------------
// cBPF encoding
// ---------------------------------------------------------------------------

const BPF_LD = 0x00;
const BPF_JMP = 0x05;
const BPF_RET = 0x06;
const BPF_W = 0x00;
const BPF_ABS = 0x20;
const BPF_JA = 0x00;
const BPF_JEQ = 0x10;
const BPF_JGE = 0x30;
const BPF_JSET = 0x40;
const BPF_K = 0x00;

const LD_ABS_W = BPF_LD | BPF_W | BPF_ABS;
const JEQ_K = BPF_JMP | BPF_JEQ | BPF_K;
const JGE_K = BPF_JMP | BPF_JGE | BPF_K;
const JSET_K = BPF_JMP | BPF_JSET | BPF_K;
const JA = BPF_JMP | BPF_JA;
const RET_K = BPF_RET | BPF_K;

// struct seccomp_data: { int nr; u32 arch; u64 ip; u64 args[6]; }
const OFF_NR = 0;
const OFF_ARCH = 4;
const offsetOfArgLow = (n: number) => 16 + n * 8;

const AUDIT_ARCH_X86_64 = 0xc000003e;
// The x32 ABI reuses x86_64's AUDIT_ARCH with bit 30 set on the syscall number.
// Without this gate, an x32 caller reaches a syscall by a number the filter
// never compares against.
const X32_SYSCALL_BIT = 0x40000000;

const SECCOMP_RET_KILL_PROCESS = 0x80000000;
const SECCOMP_RET_ERRNO = 0x00050000;
const SECCOMP_RET_ALLOW = 0x7fff0000;

const EPERM = 1;
const ENOSYS = 38;

// ---------------------------------------------------------------------------
// x86_64 syscall numbers
// ---------------------------------------------------------------------------

const SYS = {
  clone: 56,
  clone3: 435,
  socket: 41,
  ptrace: 101,
  pivot_root: 155,
  mount: 165,
  umount2: 166,
  init_module: 175,
  delete_module: 176,
  kexec_load: 246,
  add_key: 248,
  request_key: 249,
  keyctl: 250,
  unshare: 272,
  perf_event_open: 298,
  setns: 308,
  process_vm_readv: 310,
  process_vm_writev: 311,
  finit_module: 313,
  kexec_file_load: 320,
  bpf: 321,
  userfaultfd: 323,
  io_uring_setup: 425,
  open_tree: 428,
  move_mount: 429,
  fsopen: 430,
  fsconfig: 431,
  fsmount: 432,
  fspick: 433,
  mount_setattr: 442,
};

// The plan's list, in the plan's order, with the reason each one is on it.
//
// `socketcall` is in the plan and is not here: it exists only on i386, and the
// architecture gate above refuses every non-x86_64 caller before the syscall
// number is ever compared.
const DENIED: Array<[number, string]> = [
  [SYS.socket, 'no network, independently of the network namespace'],
  [SYS.unshare, 'nesting a user namespace is the escalation primitive'],
  [SYS.setns, 'the other half of unshare'],
  [SYS.ptrace, 'no reading or steering another process'],
  [SYS.process_vm_readv, 'reads another process address space directly'],
  [SYS.process_vm_writev, 'writes another process address space directly'],
  [SYS.bpf, 'kernel programs'],
  [SYS.perf_event_open, 'a long history of privilege escalation defects'],
  [SYS.io_uring_setup, 'a large syscall surface reachable without syscalls'],
  [SYS.keyctl, 'the kernel keyring is shared with the host'],
  [SYS.add_key, 'the kernel keyring is shared with the host'],
  [SYS.request_key, 'the kernel keyring is shared with the host'],
  [SYS.userfaultfd, 'used to win kernel races'],
  [SYS.mount, 'the mount namespace is built by bubblewrap and then closed'],
  [SYS.umount2, 'the other half of mount'],
  [SYS.pivot_root, 'the root is built by bubblewrap and then closed'],
  [SYS.kexec_load, 'replaces the kernel'],
  [SYS.kexec_file_load, 'replaces the kernel'],
  [SYS.init_module, 'loads kernel code'],
  [SYS.finit_module, 'loads kernel code'],
  [SYS.delete_module, 'unloads kernel code'],
  // The new mount API. Denying `mount` alone leaves these open.
  [SYS.open_tree, 'new mount API'],
  [SYS.move_mount, 'new mount API'],
  [SYS.fsopen, 'new mount API'],
  [SYS.fsconfig, 'new mount API'],
  [SYS.fsmount, 'new mount API'],
  [SYS.fspick, 'new mount API'],
  [SYS.mount_setattr, 'new mount API'],
];

// clone() is how bash forks, so it cannot simply be denied. It is denied only
// when it asks for a new namespace. CLONE_NEWUSER is the one the plan names;
// the rest are on the same argument and cost nothing to add.
const CLONE_NEWNS = 0x00020000;
const CLONE_NEWCGROUP = 0x02000000;
const CLONE_NEWUTS = 0x04000000;
const CLONE_NEWIPC = 0x08000000;
const CLONE_NEWUSER = 0x10000000;
const CLONE_NEWPID = 0x20000000;
const CLONE_NEWNET = 0x40000000;
const CLONE_NEW_ANY =
  CLONE_NEWNS |
  CLONE_NEWCGROUP |
  CLONE_NEWUTS |
  CLONE_NEWIPC |
  CLONE_NEWUSER |
  CLONE_NEWPID |
  CLONE_NEWNET;

// ---------------------------------------------------------------------------
// A very small assembler, so the jump offsets are computed rather than counted
// ---------------------------------------------------------------------------

type Insn =
  | { kind: 'label'; name: string }
  | { kind: 'stmt'; code: number; k: number }
  | { kind: 'jump'; code: number; k: number; jt: string | null; jf: string | null }
  | { kind: 'ja'; target: string };

const label = (name: string): Insn => ({ kind: 'label', name });
const ld = (offset: number): Insn => ({ kind: 'stmt', code: LD_ABS_W, k: offset });
const ret = (k: number): Insn => ({ kind: 'stmt', code: RET_K, k });
const jeq = (k: number, jt: string | null, jf: string | null): Insn => ({
  kind: 'jump',
  code: JEQ_K,
  k,
  jt,
  jf,
});
const jge = (k: number, jt: string | null, jf: string | null): Insn => ({
  kind: 'jump',
  code: JGE_K,
  k,
  jt,
  jf,
});
const jset = (k: number, jt: string | null, jf: string | null): Insn => ({
  kind: 'jump',
  code: JSET_K,
  k,
  jt,
  jf,
});
const ja = (target: string): Insn => ({ kind: 'ja', target });

export function assemble(program: Insn[]): Buffer {
  const labels = new Map<string, number>();
  let index = 0;
  for (const insn of program) {
    if (insn.kind === 'label') {
      if (labels.has(insn.name)) throw new Error(`duplicate label: ${insn.name}`);
      labels.set(insn.name, index);
    } else {
      index += 1;
    }
  }

  const resolve = (name: string) => {
    const target = labels.get(name);
    if (target === undefined) throw new Error(`unknown label: ${name}`);
    return target;
  };

  const out = Buffer.alloc(index * 8);
  let pc = 0;
  for (const insn of program) {
    if (insn.kind === 'label') continue;
    let code: number;
    let jt = 0;
    let jf = 0;
    let k: number;
    if (insn.kind === 'stmt') {
      code = insn.code;
      k = insn.k;
    } else if (insn.kind === 'ja') {
      code = JA;
      k = resolve(insn.target) - (pc + 1);
      if (k < 0) throw new Error(`backward jump to ${insn.target}`);
    } else {
      code = insn.code;
      k = insn.k;
      // A null branch falls through to the next instruction, which is offset 0.
      jt = insn.jt === null ? 0 : resolve(insn.jt) - (pc + 1);
      jf = insn.jf === null ? 0 : resolve(insn.jf) - (pc + 1);
      for (const [name, offset] of [
        ['jt', jt],
        ['jf', jf],
      ] as const) {
        if (offset < 0 || offset > 255) {
          throw new Error(`${name} offset ${offset} at instruction ${pc} is out of range`);
        }
      }
    }
    out.writeUInt16LE(code, pc * 8);
    out.writeUInt8(jt, pc * 8 + 2);
    out.writeUInt8(jf, pc * 8 + 3);
    out.writeUInt32LE(k >>> 0, pc * 8 + 4);
    pc += 1;
  }
  return out;
}

// ---------------------------------------------------------------------------
// The filter
// ---------------------------------------------------------------------------

export function buildFilter(): Buffer {
  const program: Insn[] = [
    // A filter that does not check the architecture compares syscall numbers
    // from a table it was not written for.
    ld(OFF_ARCH),
    jeq(AUDIT_ARCH_X86_64, null, 'deny_arch'),

    ld(OFF_NR),
    jge(X32_SYSCALL_BIT, 'deny_arch', null),

    jeq(SYS.clone, 'clone_flags', null),
    // clone3 puts its flags in a struct in memory, which cBPF cannot read.
    // ENOSYS makes libc fall back to clone, which the filter can inspect.
    jeq(SYS.clone3, 'deny_enosys', null),

    ...DENIED.map(([nr]) => jeq(nr, 'deny', null)),

    ja('allow'),

    label('clone_flags'),
    ld(offsetOfArgLow(0)),
    jset(CLONE_NEW_ANY, 'deny', 'allow'),

    label('allow'),
    ret(SECCOMP_RET_ALLOW),

    label('deny'),
    // EPERM rather than a kill: "Operation not permitted" is a message the
    // program can print, and error messages are the documentation here.
    ret(SECCOMP_RET_ERRNO | EPERM),

    label('deny_enosys'),
    ret(SECCOMP_RET_ERRNO | ENOSYS),

    label('deny_arch'),
    // Nothing in this image makes an x32 or i386 syscall. One that does is an
    // attack, and there is no useful errno to give it.
    ret(SECCOMP_RET_KILL_PROCESS),
  ];
  return assemble(program);
}

if (process.argv[1] && import.meta.filename === process.argv[1]) {
  const target = process.argv[2];
  if (!target) {
    process.stderr.write('usage: node generate.ts <output-path>\n');
    process.exit(2);
  }
  const { writeFileSync } = await import('node:fs');
  const filter = buildFilter();
  writeFileSync(target, filter);
  process.stderr.write(
    `wrote ${filter.length / 8} cBPF instructions (${filter.length} bytes) to ${target}\n`,
  );
}
