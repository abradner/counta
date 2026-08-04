# Guards for the copy/localisation setup. These are cheap and they protect a
# property that rots silently: one hardcoded string is invisible until someone
# tries to translate the app.
require "rails_helper"

RSpec.describe "Copy and localisation" do
  JS_DIR = Rails.root.join("app/javascript")
  VIEW_DIR = Rails.root.join("app/views")

  # Keys the JS asks for, harvested from t("…") / tNodes("…") calls.
  def js_keys
    Dir[JS_DIR.join("*.js")].flat_map { |f| File.read(f).scan(/\bt(?:Nodes)?\(\s*"([\w.]+)"/) }.flatten.uniq
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
    offenders = Dir[VIEW_DIR.join("**/*.erb")].flat_map do |file|
      next [] if file.end_with?("_pen_svg.html.erb") # SVG labels are set by JS

      # Blank out ERB spans first — including multi-line comments — keeping
      # newlines so reported line numbers still point at the real line.
      source = File.read(file).gsub(/<%.*?%>/m) { |span| "\n" * span.count("\n") }

      source.lines.each_with_index.filter_map do |line, i|
        # Text content of two 3+ letter words that isn't a tag or entity.
        text = line.gsub(/<[^>]*>/, " ").gsub(/&\w+;/, " ").strip
        "#{File.basename(file)}:#{i + 1}: #{text}" if text =~ /[A-Za-z]{3,}\s+[A-Za-z]{3,}/
      end
    end

    expect(offenders).to be_empty,
      "Copy belongs in config/locales, not in a view:\n#{offenders.join("\n")}"
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
