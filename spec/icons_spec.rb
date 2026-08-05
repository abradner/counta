require "rails_helper"

RSpec.describe "Icons" do
  SVG_SOURCE = Rails.root.join("public/icon.svg")
  SHA_FILE = Rails.root.join("public/icons/SOURCE_SHA")

  # Every SVG in the repo, and why it exists. A new one has to be added here
  # deliberately — which is the point: the icon previously lived in two files,
  # Inkscape edits went to one of them, and they drifted silently.
  KNOWN_SVGS = {
    "public/icon.svg" => "canonical app/favicon source; PNGs are rendered from it",
    "assets/counta-pen.svg" => "design source for the pen graphic (a different asset)",
    "assets/counta-prototype.html" => nil # not an SVG, listed for the reader
  }.compact.freeze

  it "has no unaccounted-for vector files" do
    found = Dir[Rails.root.join("{app,assets,public}/**/*.svg")]
              .map { |f| Pathname(f).relative_path_from(Rails.root).to_s }
              .reject { |f| f.start_with?("app/assets/images/") }

    expect(found).to match_array(KNOWN_SVGS.keys),
      "unlisted SVG(s) — if one is a second copy of the icon it will drift, " \
      "as the icon already did. Add it to KNOWN_SVGS with a reason, or delete it."
  end

  it "has PNGs rendered from the current SVG" do
    expect(SHA_FILE).to exist, "run `rake icons:render`"
    expect(SHA_FILE.read.strip).to eq(Digest::SHA256.hexdigest(SVG_SOURCE.read)),
      "public/icon.svg changed but the PNGs weren't re-rendered — run `rake icons:render`"
  end

  it "ships every size the layout and iOS ask for" do
    %w[icon.png icons/icon-192.png icons/icon-180.png icons/icon-32.png].each do |f|
      expect(Rails.root.join("public", f)).to exist
    end
  end
end
