defmodule MealplanWeb.Theme do
  @moduledoc """
  The shared "kitchen notecard" visual system: cream paper, serif ink, one
  green accent. Used by every household-facing screen that is not the MCP
  endpoint itself — the landing page, the legal pages, and the sign-in /
  consent flow (`MealplanWeb.SitePages`, `MealplanWeb.LoginPage`,
  `MealplanWeb.ConsentPage`, `MealplanWeb.KrogerPages`).

  These functions take no arguments and interpolate nothing, so they carry
  none of the escaping obligation `e/1` exists for in those modules — there
  is simply no attacker-controlled value passing through a static string.
  """

  @doc "Google Fonts `<link>` tags for the three faces the theme uses."
  def fonts do
    ~s(<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&family=Newsreader:ital,opsz,wght@0,6..72,300..600&family=Space+Mono:wght@400;700&display=swap" rel="stylesheet">)
  end

  @doc "Color variables, resets, and the handful of classes every page reaches for."
  def css do
    """
    :root {
      --paper: #faf7f0;
      --paper-alt: #f4efe4;
      --ink: #241f19;
      --ink-soft: #4a4238;
      --label: #6f6252;
      --label-soft: #7a6f60;
      --border: #e3dbcc;
      --green: #2f6b45;
      --green-dark: #26593a;
      --dark: #241f19;
      --dark-text: #f0ebe1;
      --dark-quiet: #bdb0a0;
      --dark-quiet-dim: #7a6f60;
      --dark-accent: #7fbf98;
      --soon-bg: #e8e0cf;
      --soon-text: #544a3d;
      --warn-bg: #fff8e5;
      --warn-border: #e0a800;
      --error: #a11;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--paper);
      color: var(--ink);
      font-family: 'Newsreader', Georgia, serif;
    }
    a { color: inherit; }
    h1, h2, .brand { font-family: 'Instrument Serif', Georgia, serif; font-weight: 400; }
    .mono { font-family: 'Space Mono', ui-monospace, monospace; }
    .eyebrow {
      font: 400 9.5px/1 'Space Mono', monospace;
      letter-spacing: .14em;
      text-transform: uppercase;
      color: var(--label);
    }
    code { background: rgba(0, 0, 0, .05); padding: .1rem .3rem; border-radius: 3px; overflow-wrap: anywhere; }
    .btn {
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 54px;
      background: var(--green);
      color: #f7fbf8;
      text-decoration: none;
      border-radius: 3px;
      font: 500 16.5px/1 system-ui, sans-serif;
      border: none;
      cursor: pointer;
      width: 100%;
    }
    .btn:hover { background: var(--green-dark); }
    .pill {
      font: 500 12.5px/1 system-ui, sans-serif;
      text-decoration: none;
      padding: 10px 14px;
      border: 1px solid var(--green);
      color: var(--green);
      border-radius: 100px;
      white-space: nowrap;
    }
    .pill:hover { background: var(--green); color: #f7fbf8; }
    .soon-tag {
      font: 400 9px/1 'Space Mono', monospace;
      letter-spacing: .1em;
      padding: 3px 6px;
      background: var(--soon-bg);
      color: var(--soon-text);
      border-radius: 2px;
    }
    footer, .site-footer {
      font: 400 11px/1.6 'Space Mono', monospace;
      color: var(--label);
    }
    """
  end
end
