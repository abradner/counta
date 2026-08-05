# Rasterises the canonical icon. public/icon.svg is the single source; every
# PNG here is a build artifact, never hand-edited.
#
#   mise exec -- bundle exec rake icons:render
#
# Chromium does the rasterising because there's no ImageMagick/rsvg in this
# toolchain and it's already a dependency for system specs.
namespace :icons do
  SOURCE = Rails.root.join("public/icon.svg")
  # 512 for the PWA/large, 192 Android, 180 apple-touch-icon, 32 favicon.
  SIZES = { Rails.root.join("public/icon.png") => 512,
            Rails.root.join("public/icons/icon-192.png") => 192,
            Rails.root.join("public/icons/icon-180.png") => 180,
            Rails.root.join("public/icons/icon-32.png") => 32 }.freeze

  desc "Render every PNG icon from public/icon.svg"
  task render: :environment do
    require "ferrum"
    svg = File.read(SOURCE)
    browser = Ferrum::Browser.new(browser_path: "/usr/bin/chromium", headless: true, timeout: 30)

    begin
      SIZES.each do |path, px|
        sized = svg.sub(/width="\d+" height="\d+"/, %(width="#{px}" height="#{px}"))
        File.write("/tmp/counta-icon.html",
                   "<style>html,body{margin:0;padding:0}svg{display:block}</style>#{sized}")
        page = browser.create_page
        begin
          page.set_viewport(width: px, height: px)
          page.go_to("file:///tmp/counta-icon.html")
          sleep 0.3
          FileUtils.mkdir_p(File.dirname(path))
          page.screenshot(path: path.to_s)
        ensure
          page.close
        end
        puts "  #{path.relative_path_from(Rails.root)} (#{px}px)"
      end
    ensure
      # Without this, a failure mid-render leaves a Chromium process behind.
      browser.quit
    end

    # Record what was built, and what it produced. The source SHA catches "SVG
    # edited, PNGs not re-rendered"; the artifact SHAs catch "re-rendered but
    # the binaries weren't staged", which the source stamp alone can't see.
    manifest = {
      "source" => Digest::SHA256.hexdigest(File.read(SOURCE)),
      "artifacts" => SIZES.keys.to_h do |path|
        [ path.relative_path_from(Rails.root).to_s, Digest::SHA256.hexdigest(File.binread(path)) ]
      end
    }
    Rails.root.join("public/icons/MANIFEST.json").write(JSON.pretty_generate(manifest) + "\n")
    puts "rendered from #{SOURCE.relative_path_from(Rails.root)}"
  end
end
