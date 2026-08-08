# Guards for the copy/localisation setup. These are cheap and they protect a
# property that rots silently: one hardcoded string is invisible until someone
# tries to translate the app.
require "rails_helper"

RSpec.describe "Copy and localisation" do
  JS_DIR = Rails.root.join("app/javascript")
  VIEW_DIR = Rails.root.join("app/views")

  # The wordmark is a brand name, not copy — it reads "counta.click" in every
  # language. Anything else appearing here should be justified in the same
  # breath as it's added.
  ALLOWED_LITERALS = [ "counta", ".click", "counta.click" ].freeze

  # Keys the JS asks for. Harvesting only `t("literal")` would miss the
  # conditional calls — t(flag ? "status.pen_archived" : "status.pen_unarchived")
  # — so this takes every dotted string literal in the client code and treats
  # it as a key. A literal that merely looks like one (e.g. a filename) would
  # be a false positive; there are none today, and a false positive is a
  # cheaper failure than a missing key rendering as raw text at runtime.
  KEY_SHAPED = /"([a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+)"/

  # ...restricted to literals whose first segment is an actual client
  # namespace, so unrelated dotted strings (counta.click in the ICS UIDs) don't
  # register as missing keys. Self-maintaining: add a namespace to the locale
  # file and it's covered.
  def js_keys
    namespaces = I18n.t("client").keys.map(&:to_s)
    # i18n.js is scanned too — the clicks() helper holds the only reference to
    # "dose.clicks", so skipping it left that key unguarded. Comments are
    # stripped so documentation examples don't register as real usage.
    Dir[JS_DIR.join("*.js")]
      .reject { |f| f.end_with?("wordlist.js") }
      .flat_map { |f| File.read(f).gsub(%r{//[^\n]*|/\*.*?\*/}m, "").scan(KEY_SHAPED) }
      .flatten.uniq
      .select { |key| namespaces.include?(key.split(".").first) }
  end

  it "resolves every key the client asks for" do
    client = I18n.t("client")
    missing = js_keys.reject { |key| key.split(".").reduce(client) { |n, k| n.is_a?(Hash) ? n[k.to_sym] : nil } }

    expect(missing).to be_empty,
      "JS calls t() with keys that don't exist under `client`: #{missing.join(', ')}"
  end

  it "ships every client key to the browser" do
    # The layout serialises I18n.t("client"); if that ever stops being a Hash
    # the client silently falls back to rendering raw key names.
    expect(I18n.t("client")).to be_a(Hash)
    expect(I18n.t("client").keys).to include(:dose, :errors, :warnings, :status)
  end

  it "has no user-facing copy left hardcoded in the views" do
    offenders = Dir[VIEW_DIR.join("**/*.html.erb")].flat_map do |file|
      # Only HTML templates: the PWA manifest is structured data.
      # Blank out ERB spans first — including multi-line comments — keeping
      # newlines so reported line numbers still point at the real line.
      # Blank out ERB spans AND tags across the whole file — both can span
      # lines, and stripping them per-line leaves attribute text behind, which
      # reads as prose. Newlines are preserved so line numbers stay honest.
      blank = ->(span) { "\n" * span.count("\n") }
      source = File.read(file).gsub(/<%.*?%>/m, &blank).gsub(/<[^>]*>/m, &blank)

      source.lines.each_with_index.filter_map do |line, i|
        # ANY word of 3+ letters, not just a pair: a hardcoded "Cancel" or
        # "Continue" is exactly as untranslatable as a hardcoded sentence, and
        # the two-word rule couldn't see them.
        text = line.gsub(/&\w+;/, " ").strip
        next if text.empty? || ALLOWED_LITERALS.include?(text)

        "#{File.basename(file)}:#{i + 1}: #{text}" if text =~ /[A-Za-z]{3,}/
      end
    end

    expect(offenders).to be_empty,
      "Copy belongs in config/locales, not in a view:\n#{offenders.join("\n")}"
  end

  # Dose-plan copy (#21) must never read as a recommendation. counta
  # transcribes a ladder the user and their prescriber chose; the moment the
  # copy says "recommended" or "you should", a click counter has started
  # giving medical advice — the line docs/design-notes.md "Tone" and
  # docs/data-privacy.md both draw.
  #
  # Mechanical rather than a review convention on purpose (AGENTS.md §10.5).
  PRESCRIPTIVE = /\b(recommend\w*|standard|official\w*|optimal\w*|should|safe|best dose|correct dose)\b/i

  # Every leaf string whose key path mentions the plan, across both
  # namespaces. Path-based rather than an explicit list so a key added to the
  # plan subtree later is covered without anyone remembering to add it here.
  def plan_copy
    flat = {}
    walk = lambda do |node, path|
      case node
      when Hash then node.each { |k, v| walk.call(v, path + [ k.to_s ]) }
      when Array then node.each_with_index { |v, i| walk.call(v, path + [ i.to_s ]) }
      else flat[path.join(".")] = node.to_s
      end
    end
    %w[ui.setup ui.dose client.plan client.errors client.stats].each do |root|
      walk.call(I18n.t(root), [ root ])
    end
    flat.select { |key, _| key.include?("plan") || key.include?("doses_left_at_step") }
  end

  it "keeps dose-plan copy free of anything that reads as a recommendation" do
    # Positive control first, in the same example, so the two can never drift
    # apart: if the pattern is ever tuned into something that matches nothing,
    # this fails here rather than leaving the real check silently vacuous.
    # (AGENTS.md §9.10 — the OTHER copy guard in this file was tuned until its
    # false positives went quiet, which silenced the true positives too.)
    controls = [
      "The recommended escalation is 0.25 mg.",
      "You should move up to 0.5 mg next week.",
      "This is the standard ladder.",
      "The official schedule from the manufacturer.",
      "This is the safe amount to dial."
    ]
    expect(controls.reject { |c| c.match?(PRESCRIPTIVE) }).to be_empty,
      "The prescriptive-copy guard has stopped catching prescriptive copy."
    # ...and innocuous copy must NOT trip it, or the guard is noise that will
    # get tuned away next time it fires.
    expect("Your plan moves to 1 mg after this.").not_to match(PRESCRIPTIVE)

    expect(plan_copy).not_to be_empty, "plan_copy matched nothing — the guard is scanning the wrong keys."
    offenders = plan_copy.filter_map { |key, text| "#{key}: #{text}" if text.match?(PRESCRIPTIVE) }
    expect(offenders).to be_empty,
      "Dose-plan copy must describe, never recommend:\n#{offenders.join("\n")}"
  end

  it "builds plurals with count, never by concatenating an s" do
    # The single most common localisation blocker in the original copy: many
    # languages need more than two forms, so `n + (n === 1 ? "" : "s")` is
    # untranslatable by construction.
    offenders = Dir[JS_DIR.join("*.js")].flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, i|
        "#{File.basename(file)}:#{i + 1}" if line =~ /\?\s*"[^"]*"\s*:\s*"s"|"s"\s*:\s*""/
      end
    end

    expect(offenders).to be_empty, "Hand-rolled plural(s) at:\n#{offenders.join("\n")}"
  end
end
