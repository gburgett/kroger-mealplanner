defmodule MealplanWeb.SitePages do
  @moduledoc """
  The public, ungated landing page at `/`. Rebranded to Plantrify from a
  Claude Design handoff, on top of the content originally ported from the
  plain-text placeholder in `MealplanWeb.StatusController` (plan 0005 Phase 8,
  ADR 0026).

  Plain HTML in a heredoc, for the reason `MealplanWeb.ConsentPage` and
  `MealplanWeb.KrogerPages` give: a template engine running outside the sandbox,
  in the process that holds the household's credentials, is a bad trade for one
  page of markup. `e/1` is the same five-character escape. Shared colors and
  fonts live in `MealplanWeb.Theme`.

  This page authorises nothing and changes no state, so it is not a third
  screen in AGENTS.md's count (ADR 0026). Two audiences read it: a person
  deciding whether to connect, and an assistant fetching the URL on the
  household's behalf. The second audience is why the connector steps and the
  ChatGPT / Claude / Gemini caveats are spelled out here rather than left to
  the model's training data, which goes stale (ADR 0026, Context), and why the
  "Note for AI assistants" block is a collapsed `<details>` rather than left
  out: a human sees one quiet line, an assistant reads the same DOM either way.

  The Terms of Service, Privacy Policy and contact form are flat files under
  `priv/static/`, served by `Plug.Static` — see `MealplanWeb.static_paths/0`.
  """

  alias MealplanWeb.Theme

  @style """

    body { font-family: 'Newsreader', Georgia, serif; color: var(--ink); }

    .nav {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 18px 22px 0;
      max-width: 32rem;
      margin: 0 auto;
    }
    .nav .brand { font: 400 20px/1 'Instrument Serif', Georgia, serif; }

    .hero {
      max-width: 32rem;
      margin: 0 auto;
      padding: 32px 22px 34px;
      display: flex;
      flex-direction: column;
      gap: 18px;
    }
    .hero h1 {
      margin: 0;
      font: 400 40px/1.05 'Instrument Serif', Georgia, serif;
      letter-spacing: -.012em;
      text-wrap: pretty;
    }
    .hero p {
      margin: 0;
      font: 300 16.5px/1.55 'Newsreader', Georgia, serif;
      color: var(--ink-soft);
      max-width: 32ch;
      text-wrap: pretty;
    }
    .beta-note { font-size: 11.5px; color: var(--label-soft); }

    .carousel-section {
      padding: 30px 0 32px;
      background: var(--paper-alt);
      border-top: 1px solid var(--border);
      border-bottom: 1px solid var(--border);
    }
    .carousel-head {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      max-width: 32rem;
      margin: 0 auto 16px;
      padding: 0 22px;
    }
    .swipe-hint { font-size: 9.5px; letter-spacing: .06em; color: var(--label-soft); }

    .pt-car {
      display: flex;
      overflow-x: auto;
      scroll-snap-type: x mandatory;
      scroll-behavior: smooth;
      scrollbar-width: none;
      -webkit-overflow-scrolling: touch;
      max-width: 32rem;
      margin: 0 auto;
    }
    .pt-car::-webkit-scrollbar { display: none; }
    .pt-slide {
      width: 100%;
      flex: none;
      box-sizing: border-box;
      padding: 0 22px;
      scroll-snap-align: center;
    }
    .pt-slide-label {
      font: 400 9.5px/1 'Space Mono', monospace;
      letter-spacing: .12em;
      text-transform: uppercase;
      color: var(--green);
      margin-bottom: 10px;
    }
    .demo-card {
      background: #fff;
      border: 1px solid var(--border);
      border-radius: 3px;
      padding: 17px 18px;
      font: 300 14.5px/1.6 'Newsreader', Georgia, serif;
      color: #332c23;
      box-shadow: 0 1px 0 #e8e0d0;
    }
    .result-divider {
      display: flex;
      align-items: center;
      gap: 10px;
      margin: 20px 0 14px;
      font: 400 9.5px/1 'Space Mono', monospace;
      letter-spacing: .14em;
      text-transform: uppercase;
      color: var(--label);
    }
    .result-divider span { flex: 1; height: 1px; background: #e0d7c6; }
    .day-list { display: flex; flex-direction: column; gap: 9px; }
    .day-row {
      display: flex;
      gap: 12px;
      padding: 12px 14px;
      background: #fff;
      border-left: 2px solid var(--green);
    }
    .day-row.muted { border-left-color: #b8a98e; }
    .day-row.result { background: var(--green); color: #f4f9f5; border-left: none; }
    .day-row .day-label { font-size: 10px; line-height: 1.6; color: var(--label); width: 34px; flex: none; }
    .day-row.result .day-label { color: inherit; opacity: .7; }
    .day-row .day-text { font: 300 14.5px/1.45 'Newsreader', Georgia, serif; }

    .pt-dots {
      display: flex;
      justify-content: center;
      gap: 8px;
      margin-top: 22px;
    }
    .pt-dot {
      width: 26px;
      height: 26px;
      padding: 0;
      border: 0;
      background: none;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .pt-dot span {
      width: 7px;
      height: 7px;
      border-radius: 100px;
      background: #cdc2ad;
      display: block;
    }
    .pt-dot.is-active span { background: var(--green); }

    .good-at, .recipes-section, .store-section, .faq-section {
      max-width: 32rem;
      margin: 0 auto;
      padding: 32px 22px;
    }
    .good-list { display: flex; flex-direction: column; gap: 20px; margin-top: 22px; }
    .good-title { font: 400 21px/1.15 'Instrument Serif', Georgia, serif; margin-bottom: 5px; }
    .good-desc { font: 300 14.5px/1.5 'Newsreader', Georgia, serif; color: var(--ink-soft); }

    .recipes-section {
      background: var(--paper-alt);
      border-top: 1px solid var(--border);
      display: flex;
      flex-direction: column;
      gap: 18px;
      max-width: none;
      padding-left: 0;
      padding-right: 0;
    }
    .recipes-section > * { max-width: 32rem; margin: 0 auto; width: 100%; padding-left: 22px; padding-right: 22px; box-sizing: border-box; }
    .recipes-section h2 {
      margin: 0;
      font: 400 27px/1.15 'Instrument Serif', Georgia, serif;
      letter-spacing: -.01em;
      text-wrap: pretty;
    }
    .recipes-section p { margin: 0; font: 300 15px/1.55 'Newsreader', Georgia, serif; color: var(--ink-soft); text-wrap: pretty; }
    .step-list { display: flex; flex-direction: column; gap: 9px; }
    .step-row {
      display: flex;
      gap: 13px;
      align-items: flex-start;
      background: #fff;
      border: 1px solid var(--border);
      padding: 14px 15px;
      font: 300 14.5px/1.5 'Newsreader', Georgia, serif;
      color: #332c23;
    }
    .step-row.soon { background: #efe8da; border: 1px dashed #cfc2a9; color: var(--soon-text); }
    .step-num { color: var(--green); flex: none; width: 16px; font-size: 10px; line-height: 1.6; }
    .step-row.soon .step-num { color: var(--label); }

    .store-section { display: flex; flex-direction: column; gap: 18px; }
    .store-section p { margin: 0; font: 300 15px/1.55 'Newsreader', Georgia, serif; color: var(--ink-soft); text-wrap: pretty; }
    .store-list { display: flex; flex-direction: column; gap: 1px; background: var(--border); border: 1px solid var(--border); }
    .store-row { display: flex; align-items: center; justify-content: space-between; background: #faf7f0; padding: 15px 16px; }
    .store-row-live { background: #fff; }
    .store-name { font: 400 17px/1.2 'Instrument Serif', Georgia, serif; color: var(--ink); }
    .store-name.soon { color: var(--label); }
    .store-status { font-size: 9.5px; letter-spacing: .1em; text-transform: uppercase; }
    .store-status.live { display: flex; align-items: center; gap: 7px; color: var(--green); }
    .store-status.live .dot { width: 6px; height: 6px; border-radius: 100px; background: var(--green); display: block; }
    .store-status.soon { color: var(--label-soft); }
    .store-disclaimer { font: 300 12.5px/1.5 'Newsreader', Georgia, serif; color: var(--label); }

    .connect-section {
      background: var(--dark);
      color: var(--dark-text);
      padding: 30px 22px 34px;
    }
    .connect-eyebrow { color: var(--dark-quiet); margin-bottom: 18px; }
    .connect-list, .ai-note, .connect-section > .eyebrow, .connect-section h2 {
      max-width: 32rem;
      margin-left: auto;
      margin-right: auto;
    }
    .connect-list { display: flex; flex-direction: column; gap: 14px; }
    .connect-row {
      display: flex;
      gap: 14px;
      align-items: flex-start;
      padding-bottom: 14px;
      border-bottom: 1px solid rgba(255,255,255,.1);
    }
    .connect-row-last { border-bottom: none; padding-bottom: 0; }
    .connect-app { font-size: 11px; line-height: 1.5; color: var(--dark-accent); flex: none; width: 62px; }
    .connect-desc { font: 300 14px/1.5 'Newsreader', Georgia, serif; color: #d8d0c2; }

    .ai-note { margin-top: 20px; padding-top: 18px; border-top: 1px solid rgba(255,255,255,.1); }
    .ai-note summary {
      font-size: 9.5px;
      letter-spacing: .14em;
      text-transform: uppercase;
      color: var(--dark-quiet-dim);
      cursor: pointer;
      list-style: none;
      min-height: 24px;
      display: flex;
      align-items: center;
    }
    .ai-note summary::-webkit-details-marker { display: none; }
    .ai-note summary:hover { color: var(--dark-quiet); }
    .ai-note-body { font: 300 13px/1.6 'Newsreader', Georgia, serif; color: var(--dark-quiet); text-wrap: pretty; margin-top: 10px; }
    .ai-note-url { color: var(--dark-accent); font-size: 12px; }
    .ai-note-link { color: var(--dark-accent); text-decoration: none; border-bottom: 1px solid rgba(127,191,152,.4); }

    .faq-section { display: flex; flex-direction: column; }
    .faq-list { display: flex; flex-direction: column; gap: 18px; margin-top: 18px; }
    .faq-q { font: 500 16px/1.3 'Newsreader', Georgia, serif; margin-bottom: 5px; }
    .faq-a { font: 300 14.5px/1.55 'Newsreader', Georgia, serif; color: var(--ink-soft); }

    .cta-section {
      max-width: 32rem;
      margin: 0 auto;
      padding: 34px 22px 26px;
      background: var(--paper-alt);
      border-top: 1px solid var(--border);
      display: flex;
      flex-direction: column;
      gap: 16px;
    }
    .cta-section h2 { margin: 0; font-size: 26px; line-height: 1.15; }
    .footer-row { display: flex; justify-content: space-between; padding-top: 10px; }
    .footer-row a { text-decoration: none; }
  """

  @doc "The landing page. `mcp_url` is this server's own `<public_url>/mcp`."
  def landing(mcp_url) do
    u = e(mcp_url)

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Plantrify</title>
    <meta name="description" content="Meal planning that takes 2 minutes. Tell Claude, ChatGPT, or Gemini what your week looks like and Plantrify plans the meals, remembers what your family eats, and hands you one shopping list.">
    #{Theme.fonts()}
    <style>
    #{Theme.css()}
    #{@style}
    </style>
    </head>
    <body>

    <nav class="nav">
      <div class="brand">plantrify</div>
      <a href="/contact.html" class="pill">Get invited</a>
    </nav>

    <header class="hero">
      <h1>Meal planning that takes 2 minutes &mdash; because you have 2 minutes.</h1>
      <p>Tell Claude, ChatGPT, or Gemini what your week actually looks like.
      Plantrify plans the meals, remembers what your family will eat, and hands
      you one shopping list. There's no app to download.</p>
      <a href="/contact.html" class="btn">Ask for an invitation</a>
      <div class="beta-note mono">Free during the invite-only beta.</div>
    </header>

    <section class="carousel-section">
      <div class="carousel-head">
        <div class="eyebrow">What you actually type</div>
        <div class="swipe-hint mono">Swipe &rarr;</div>
      </div>

      <div id="pt-car" class="pt-car">

        <div class="pt-slide">
          <div class="pt-slide-label">A regular week</div>
          <div class="demo-card">It's just us this week.&nbsp; Plan 4 dinners, remix
          some of our faves. Feeling like italian for tomorrow and maybe asian
          later this week. Leave Friday open for pizza.</div>
          #{result_divider()}
          <div class="day-list">
            #{day_row("MON", "Turkey spaghetti &middot; garlic bread")}
            #{day_row("TUE", "Sheet-pan chicken &amp; potatoes")}
            #{day_row("WED", "Beef tacos, toddler-friendly")}
            #{day_row("THU", "Teriyaki rice bowls")}
            #{day_row("FRI", "Pizza night &mdash; nothing to buy", muted: true)}
            #{result_row("One list, 24 items, added to your Kroger cart")}
          </div>
        </div>

        <div class="pt-slide">
          <div class="pt-slide-label">Hosting a cookout</div>
          <div class="demo-card">We're hosting a cookout Saturday for about 14
          people, half of them kids. Burgers and dogs on the grill, plus two
          sides that hold up outside and something for a vegetarian friend.</div>
          #{result_divider()}
          <div class="day-list">
            #{day_row("MAIN", "Burgers &amp; dogs, 14 servings")}
            #{day_row("VEG", "Black bean burgers &times;3")}
            #{day_row("SIDE", "Corn salad &middot; potato salad")}
            #{day_row("KIDS", "Fruit tray &middot; juice boxes")}
            #{day_row("EXTRA", "Buns, condiments, ice, plates", muted: true)}
            #{result_row("One list, 38 items, scaled for 14")}
          </div>
        </div>

        <div class="pt-slide">
          <div class="pt-slide-label">Planning a trip</div>
          <div class="demo-card">Help me make a meal plan for next week. We'll be
          in an AirBNB in Colorado with a full kitchen. We want to cook 3 meals
          in. Simple stuff like spaghetti (we sub ground turkey). Suggest two
          more. We also need breakfasts for all 5 days.&nbsp; We have a 3-year-old
          and an 18-month-old, and we like breakfast tacos, pancakes, waffles,
          bacon.</div>
          #{result_divider()}
          <div class="day-list">
            #{day_row("MON", "Turkey spaghetti &middot; garlic bread")}
            #{day_row("TUE", "Sheet-pan chicken &amp; potatoes")}
            #{day_row("WED", "Beef tacos, toddler-friendly")}
            #{day_row("A.M.", "Breakfast tacos &times;2, pancakes &times;2, waffles + bacon", muted: true)}
            #{result_row("One list, 31 items, pickup when you land")}
          </div>
        </div>

      </div>

      <div class="pt-dots">
        <button type="button" class="pt-dot" data-i="0" aria-label="Regular week"><span></span></button>
        <button type="button" class="pt-dot" data-i="1" aria-label="Cookout"><span></span></button>
        <button type="button" class="pt-dot" data-i="2" aria-label="Trip"><span></span></button>
      </div>
    </section>

    <section class="good-at">
      <div class="eyebrow">What it's good at</div>
      <div class="good-list">
        <div>
          <div class="good-title">It remembers</div>
          <div class="good-desc">Ground turkey instead of beef. No mushrooms. The
          one pasta the toddler eats. Say it once.</div>
        </div>
        <div>
          <div class="good-title">It shops</div>
          <div class="good-desc">Your plan becomes a grocery list and lands in
          your store's cart, aisle by aisle.</div>
        </div>
        <div>
          <div class="good-title">It counts macros <span class="soon-tag">SOON</span></div>
          <div class="good-desc">Protein targets, calorie ranges, and plans that
          hit them &mdash; without leaving the chat.</div>
        </div>
      </div>
    </section>

    <section class="recipes-section">
      <div class="eyebrow">Your own recipes</div>
      <h2>The recipes you already cook.</h2>
      <p>Snap a photo of a page from your recipe book or a card in your
      mother-in-law's handwriting. Your AI uses Plantrify to read the
      ingredients, remember the recipe, and use it the next time you plan a
      week.</p>
      <div class="step-list">
        <div class="step-row">
          <div class="step-num mono">1</div>
          <div><strong>Take the photo.</strong> Send it to your AI like you'd
          send it to a friend.</div>
        </div>
        <div class="step-row">
          <div class="step-num mono">2</div>
          <div><strong>It gets saved.</strong> Ingredients, servings, and the
          steps &mdash; kept in your own recipe box.</div>
        </div>
        <div class="step-row">
          <div class="step-num mono">3</div>
          <div><strong>Ask for it by name.</strong> &ldquo;Put Grandma's chili on
          the plan Thursday.&rdquo;</div>
        </div>
        <div class="step-row soon">
          <div class="step-num mono">4</div>
          <div><strong>Import from Pinterest</strong> <span class="soon-tag">SOON</span><br>
          Point us at a board and we'll pull the recipes in.</div>
        </div>
      </div>
    </section>

    <section class="store-section">
      <div class="eyebrow">Works with your store</div>
      <p>Your shopping list gets placed in your online cart ready for pickup at
      a real store.</p>
      <div class="store-list">
        <div class="store-row store-row-live">
          <div class="store-name">Kroger</div>
          <div class="store-status live mono"><span class="dot"></span>Live</div>
        </div>
        <div class="store-row">
          <div class="store-name soon">Walmart</div>
          <div class="store-status soon mono">Coming soon</div>
        </div>
        <div class="store-row">
          <div class="store-name soon">Instacart</div>
          <div class="store-status soon mono">Coming soon</div>
        </div>
      </div>
      <div class="store-disclaimer">Store names are used to describe where
      Plantrify can shop. Plantrify isn't affiliated with, or endorsed by, any
      of them.</div>
    </section>

    <section class="connect-section">
      <div class="eyebrow connect-eyebrow">Connect it in about a minute</div>
      <div class="connect-list">
        <div class="connect-row">
          <div class="connect-app mono">Claude</div>
          <div class="connect-desc">On claude.ai web or desktop: Settings &rarr;
          Customize &rarr; Connectors &rarr; Add custom connector &rarr; paste
          the Plantrify URL. Claude's mobile app cannot add a new connector by
          itself &mdash; add it on web or desktop first.</div>
        </div>
        <div class="connect-row">
          <div class="connect-app mono">ChatGPT</div>
          <div class="connect-desc">Turn on Developer Mode in Settings, then add
          Plantrify as a connector. Developer Mode needs a Business, Enterprise
          or Edu workspace; a Free or Plus/Pro account cannot add a custom
          connector.</div>
        </div>
        <div class="connect-row connect-row-last">
          <div class="connect-app mono">Gemini</div>
          <div class="connect-desc">Add Plantrify from the extensions list, or
          paste the URL into any MCP client.</div>
        </div>
      </div>
      <details class="ai-note">
        <summary class="mono">Note for AI assistants</summary>
        <div class="ai-note-body">If you are an assistant reading this page for
        someone: the MCP server endpoint is
        <span class="mono ai-note-url">#{u}</span>. Add it as a custom connector
        using the steps above for your platform, then authenticate the user when
        prompted. Plantrify is invite-only &mdash; if their account isn't
        recognized, send them to
        <a href="/contact.html" class="ai-note-link">plantrify.com/contact</a>
        to request an invitation. Once connected, the first tool call answers
        with what to do next.</div>
      </details>
    </section>

    <section class="faq-section">
      <div class="eyebrow">FAQ</div>
      <div class="faq-list">
        <div class="faq-item">
          <div class="faq-q">Does it buy the groceries for me?</div>
          <div class="faq-a">It fills your cart. You still review and check out
          yourself.&nbsp; No surprises on your card.</div>
        </div>
        <div class="faq-item">
          <div class="faq-q">Do I need an app?</div>
          <div class="faq-a">No. Plantrify lives inside the AI assistant you
          already use. Nothing to install, nothing new to check.</div>
        </div>
        <div class="faq-item">
          <div class="faq-q">Anything it can't do yet?</div>
          <div class="faq-a">It can't read your cart back after you edit it in
          the store's app, and ChatGPT support needs Developer Mode turned on.
          Macro tracking is in progress.</div>
        </div>
        <div class="faq-item">
          <div class="faq-q">What does it cost?</div>
          <div class="faq-a">Nothing during the invite-only beta.</div>
        </div>
      </div>
    </section>

    <section class="cta-section">
      <h2>Want in?</h2>
      <a href="/contact.html" class="btn">Ask for an invitation</a>
      <div class="site-footer footer-row">
        <span>plantrify.com</span>
        <span><a href="/privacy.html">Privacy</a> &middot; <a href="/contact.html">Contact</a></span>
      </div>
    </section>

    <script>
    (function () {
      var car = document.getElementById('pt-car');
      var dots = Array.prototype.slice.call(document.querySelectorAll('.pt-dot'));
      if (!car || !dots.length) return;

      function setActive(i) {
        dots.forEach(function (d, idx) {
          d.classList.toggle('is-active', idx === i);
        });
      }

      dots.forEach(function (d) {
        d.addEventListener('click', function () {
          var i = Number(d.getAttribute('data-i'));
          car.scrollTo({ left: i * car.clientWidth, behavior: 'smooth' });
        });
      });

      car.addEventListener('scroll', function () {
        if (!car.clientWidth) return;
        var i = Math.round(car.scrollLeft / car.clientWidth);
        setActive(i);
      });

      setActive(0);
    })();
    </script>

    </body>
    </html>
    """
  end

  defp result_divider do
    ~s(<div class="result-divider"><span></span><div class="mono">What comes back</div><span></span></div>)
  end

  defp day_row(label, text, opts \\ []) do
    css = if opts[:muted], do: " muted", else: ""
    ~s(<div class="day-row#{css}"><div class="day-label mono">#{label}</div><div class="day-text">#{text}</div></div>)
  end

  defp result_row(text) do
    ~s(<div class="day-row result"><div class="day-label mono">&rarr;</div><div class="day-text">#{text}</div></div>)
  end

  # The same five-character escape ConsentPage and KrogerPages carry. `mcp_url`
  # is this server's own configuration, not attacker input, but the escape costs
  # nothing and keeps every page in this app consistent.
  defp e(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
