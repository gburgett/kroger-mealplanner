defmodule Mealplan.Features.InvitationsSteps do
  @moduledoc """
  The operator inviting households, and each invited household planning in its
  own folder. See `features/invitations.feature` and ADR 0033.

  These steps drive the real endpoint over loopback: `/login` and `/login/code`
  for a household's sign-in, `Mealplan.McpClient` for its approved client, and
  `mix mealplan.invite` for the command-line half. Below the controller the
  only stand-in is `Mealplan.Mock.SuperTokens`, the core and the SMS provider —
  the one kind of thing this suite mocks.

  A household is addressed by its telephone throughout. `context.clients` maps a
  telephone to its `Mealplan.McpClient`; `context.logins` maps one to its
  browser cookies; `context.tenants` maps one to the tenant slug it owns.
  `context.current_phone` is "that household" for the bare `that client` steps.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions
  import Ecto.Query, only: [from: 2]

  alias Mealplan.{Accounts, Browser, Invitations, McpClient, Tenancy}
  alias Mealplan.Features.CorpusHooks
  alias Mealplan.Mock.SuperTokens

  # --- the operator's command line ----------------------------------------

  step "no household has been invited", context do
    for slug <- Mealplan.Repo.all(from(t in Accounts.Tenant, select: t.slug)) do
      CorpusHooks.close_session(slug)
    end

    Mealplan.Repo.delete_all(Accounts.Invitation)
    Mealplan.Repo.delete_all(Accounts.Membership)
    Mealplan.Repo.delete_all(Accounts.Tenant)
    Mealplan.Repo.delete_all(Accounts.User)

    {:ok, context |> Map.put(:clients, %{}) |> Map.put(:logins, %{}) |> Map.put(:tenants, %{})}
  end

  step "the operator invites {string}", %{args: [phone]} = context do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    ExUnit.Callbacks.on_exit(fn -> Mix.shell(shell) end)

    Mix.Task.rerun("mealplan.invite", [phone])

    {:ok, Map.put(context, :task_output, drain_shell())}
  end

  step "the operator revokes the invitation for {string}", %{args: [phone]} = context do
    {:ok, _} = Invitations.revoke(phone)
    {:ok, context}
  end

  step "{string} has an open invitation", %{args: [phone]} = context do
    invitation = Invitations.get_by_phone(phone)
    assert invitation, "there is no invitation for #{phone}"
    refute invitation.redeemed_at, "the invitation for #{phone} has already been redeemed"
    {:ok, context}
  end

  step "no household has been provisioned for {string} yet", %{args: [phone]} = context do
    refute Tenancy.tenant_for_phone(phone), "#{phone} already owns a tenant"
    {:ok, context}
  end

  step "the sandbox backend is bubblewrap", context do
    key = Mealplan.Sandbox
    previous = Application.get_env(:mealplan, key, [])
    Application.put_env(:mealplan, key, Keyword.put(previous, :mode, :bubblewrap))
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:mealplan, key, previous) end)
    {:ok, context}
  end

  step "the task warns that bubblewrap shares one kernel between households", context do
    assert context.task_output =~ ~r/bubblewrap/i,
           "the task said nothing about bubblewrap:\n#{context.task_output}"

    assert context.task_output =~ ~r/one kernel|shares one kernel/i,
           "the task did not warn about a shared kernel:\n#{context.task_output}"

    {:ok, context}
  end

  step "the task names microsandbox as the isolating backend", context do
    assert context.task_output =~ ~r/microsandbox/i,
           "the task did not name microsandbox:\n#{context.task_output}"

    {:ok, context}
  end

  # --- inviting, for the scenarios that only need the row -----------------

  step "{string} has been invited", %{args: [phone]} = context do
    ensure_invited(phone)
    {:ok, context}
  end

  step "the household {string} has been invited", %{args: [phone]} = context do
    ensure_invited(phone)
    {:ok, context}
  end

  step "{string} has been invited and has approved a client", %{args: [phone]} = context do
    ensure_invited(phone)
    client = McpClient.connect(phone)
    assert client.access_token, "#{phone} did not come away with a token"

    {:ok,
     context
     |> put_client(phone, client)
     |> remember_tenant(phone)
     |> Map.put(:current_phone, phone)}
  end

  step "the household {string} exists", %{args: [phone]} = context do
    ensure_invited(phone)
    _ = McpClient.connect(phone)
    {:ok, context |> remember_tenant(phone) |> Map.put(:current_phone, phone)}
  end

  # --- a household's sign-in --------------------------------------------

  step "someone asks for a code for {string}", %{args: [phone]} = context do
    {:ok, Map.put(context, :response, Browser.post("/login", %{"phone" => phone, "return_to" => "/"}))}
  end

  step "the household {string} asks for a code", %{args: [phone]} = context do
    response = Browser.post("/login", %{"phone" => phone, "return_to" => "/"})

    {:ok,
     context
     |> Map.put(:response, response)
     |> put_login(phone, login_cookie: cookie_of(response))}
  end

  step "the household {string} enters that code", %{args: [phone]} = context do
    {:ok, enter_code(context, phone)}
  end

  step "the household {string} signs out", %{args: [phone]} = context do
    login = get_login(context, phone)
    cookie = login[:session_cookie] || login[:login_cookie]
    headers = if cookie, do: [{"cookie", cookie}], else: []
    response = Browser.post("/logout", %{}, headers)

    {:ok,
     context
     |> Map.put(:response, response)
     |> put_login(phone, session_cookie: nil, login_cookie: nil)}
  end

  step "the household {string} signs in again", %{args: [phone]} = context do
    asked = Browser.post("/login", %{"phone" => phone, "return_to" => "/"})
    context = put_login(context, phone, login_cookie: cookie_of(asked))
    {:ok, enter_code(context, phone)}
  end

  step "the household {string} approves a client", %{args: [phone]} = context do
    client = McpClient.connect(phone)
    assert client.access_token, "#{phone} did not come away with a token"

    {:ok,
     context
     |> put_client(phone, client)
     |> remember_tenant(phone)
     |> Map.put(:current_phone, phone)}
  end

  step "the operator invites {string} into the household {string}",
       %{args: [new_phone, _household_phone]} = context do
    # @future: a second telephone joins an existing household. Not built here
    # (ADR 0033), so the invite is an ordinary one and the scenario is @future.
    ensure_invited(new_phone)
    {:ok, context}
  end

  step "{string} signs in with the code that arrives", %{args: [phone]} = context do
    asked = Browser.post("/login", %{"phone" => phone, "return_to" => "/"})
    context = put_login(context, phone, login_cookie: cookie_of(asked))
    {:ok, enter_code(context, phone)}
  end

  # --- what is true afterwards -----------------------------------------

  step "the household {string} is signed in", %{args: [phone]} = context do
    login = get_login(context, phone)

    assert login[:session_cookie],
           "no session cookie for #{phone} (status #{inspect(login[:status])})"

    {:ok, context}
  end

  step "{string} is the owner of its own tenant", %{args: [phone]} = context do
    tenant = Tenancy.tenant_for_phone(phone)
    assert tenant, "#{phone} owns no tenant"
    assert Accounts.owner?(tenant, phone), "#{phone} is not an owner of #{tenant.slug}"
    {:ok, put_tenant(context, phone, tenant.slug)}
  end

  step "it is the same tenant as before", context do
    phone = context.current_phone
    before = get_tenant(context, phone)
    now = Tenancy.tenant_for_phone(phone)

    assert now && now.slug == before,
           "the tenant changed for #{phone}: #{inspect(before)} -> #{inspect(now && now.slug)}"

    {:ok, context}
  end

  step "both telephones plan meals in the same folder", context do
    [a, b] = Map.keys(context.tenants)
    assert get_tenant(context, a) == get_tenant(context, b)
    {:ok, context}
  end

  step "each client worked only in its own household's folder", context do
    phones = Map.keys(context.clients)
    assert length(phones) >= 2, "this scenario needs at least two clients"

    tenants = for p <- phones, do: Tenancy.tenant_for_phone(p)
    paths = for t <- tenants, do: Tenancy.corpus_path(t)

    assert length(Enum.uniq(paths)) == length(paths),
           "two households share a folder: #{inspect(paths)}"

    pids = for t <- tenants, do: Mealplan.Sandbox.whereis(t.slug)

    assert Enum.all?(pids, &is_pid/1) and length(Enum.uniq(pids)) == length(pids),
           "the households do not each have their own live session: #{inspect(pids)}"

    {:ok, context}
  end

  # --- a household's assistant at work --------------------------------

  step "that household's assistant has written a recipe {string}", %{args: [name]} = context do
    phone = context.current_phone
    marker = "SECRET-#{name}-#{System.unique_integer([:positive])}"
    content = "# #{name}\n\n#{marker}\n"

    {client, result} =
      McpClient.run(
        get_client(context, phone),
        "mkdir -p recipes && printf '%s' #{shq(content)} > recipes/#{name}.md",
        "add recipe #{name}"
      )

    assert result.exit_code == 0, "writing the recipe failed:\n#{result.text}"

    {:ok,
     context
     |> put_client(phone, client)
     |> Map.put(:secret_recipe, %{name: name, marker: marker})}
  end

  step "that client runs {string}", %{args: [command]} = context do
    run_client(context, context.current_phone, command)
  end

  step "the {string} client runs {string}", %{args: [phone, command]} = context do
    run_client(context, phone, command)
  end

  step "the {string} client still runs {string} and it succeeds",
       %{args: [phone, command]} = context do
    {:ok, context} = run_client(context, phone, command)

    assert context[:last] && context.last.exit_code == 0,
           "expected #{phone}'s client to still work, got #{inspect(context[:last])}"

    {:ok, context}
  end

  step "the output names {string}", %{args: [text]} = context do
    assert output_of(context) =~ text,
           "#{inspect(text)} is not in the output:\n#{output_of(context)}"

    {:ok, context}
  end

  step "the output holds nothing from the other household's recipe", context do
    marker = context.secret_recipe.marker

    refute output_of(context) =~ marker,
           "the other household's recipe body leaked:\n#{output_of(context)}"

    {:ok, context}
  end

  step "the recipe {string} is still in its folder", %{args: [name]} = context do
    phone = context.current_phone
    {client, result} = McpClient.run(get_client(context, phone), "cat recipes/#{name}.md")

    assert result.exit_code == 0 and result.stdout =~ name,
           "recipe #{name} is not in #{phone}'s folder:\n#{result.text}"

    {:ok, put_client(context, phone, client)}
  end

  step "the answer does not say whether that number was invited", context do
    response = context.response
    assert response.status == 200, "a refused number answered #{response.status}, not the code form"

    assert response.body =~ ~s(name="code"),
           "a refused number did not get the code form a real send gets"

    refute response.body =~ ~r/not invited|no invitation|unknown number|no such/i,
           "the page says whether the number was invited"

    {:ok, context}
  end

  # --- helpers -------------------------------------------------------

  defp ensure_invited(phone) do
    case Invitations.get_by_phone(phone) do
      nil -> {:ok, _} = Invitations.create(phone)
      _ -> :ok
    end
  end

  defp enter_code(context, phone) do
    code = SuperTokens.last_code(context.supertokens) || flunk("no code reached #{phone}")
    login = get_login(context, phone)
    cookie = login[:login_cookie] || login[:session_cookie]
    headers = if cookie, do: [{"cookie", cookie}], else: []
    response = Browser.post("/login/code", %{"code" => code, "return_to" => "/"}, headers)

    session_cookie = if response.status in 200..399, do: cookie_of(response)

    context
    |> Map.put(:response, response)
    |> put_login(phone,
      session_cookie: session_cookie,
      login_cookie: cookie_of(response) || login[:login_cookie],
      status: response.status
    )
  end

  defp run_client(context, phone, command) do
    client = get_client(context, phone)
    command = String.replace(command, ~S(\"), ~S("))

    try do
      {client, result} = McpClient.run(client, command)

      last = %{
        stdout: result.stdout,
        stderr: result.stderr,
        exit_code: result.exit_code,
        timed_out: false,
        truncated: false,
        text: result.text
      }

      {:ok,
       context
       |> put_client(phone, client)
       |> Map.put(:last, last)
       |> Map.put(:current_phone, phone)
       |> Map.delete(:response)}
    rescue
      error in [RuntimeError] ->
        message = Exception.message(error)
        status = if message =~ ~r/refused: 401/, do: 401, else: 500

        {:ok,
         context
         |> Map.put(:response, %{status: status, body: message, location: nil})
         |> Map.put(:last, nil)
         |> Map.put(:current_phone, phone)}
    end
  end

  defp output_of(context) do
    last = context[:last] || flunk("no client command has run in this scenario yet")
    String.trim_trailing("#{last.stdout}\n#{last.stderr}\n#{last.text}")
  end

  defp drain_shell(acc \\ []) do
    receive do
      {:mix_shell, _kind, [message]} -> drain_shell([message | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp shq(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp put_client(context, phone, client),
    do: Map.update(context, :clients, %{phone => client}, &Map.put(&1, phone, client))

  defp get_client(context, phone) do
    (context[:clients] || %{})[phone] || flunk("no client has been approved for #{phone}")
  end

  defp put_login(context, phone, fields) do
    current = (context[:logins] || %{})[phone] || %{}
    merged = Enum.reduce(fields, current, fn {k, v}, acc -> Map.put(acc, k, v) end)
    Map.update(context, :logins, %{phone => merged}, &Map.put(&1, phone, merged))
  end

  defp get_login(context, phone), do: (context[:logins] || %{})[phone] || %{}

  defp put_tenant(context, phone, slug),
    do: Map.update(context, :tenants, %{phone => slug}, &Map.put(&1, phone, slug))

  defp get_tenant(context, phone), do: (context[:tenants] || %{})[phone]

  defp remember_tenant(context, phone) do
    case Tenancy.tenant_for_phone(phone) do
      %{slug: slug} -> put_tenant(context, phone, slug)
      _ -> context
    end
  end

  defp cookie_of(%{set_cookie: cookies}) do
    Enum.find_value(cookies, fn cookie ->
      case String.split(cookie, ";", parts: 2) do
        ["_mealplan_key=" <> _ = pair | _] -> pair
        _ -> nil
      end
    end)
  end

  defp cookie_of(_), do: nil
end
