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

    SIZES.each do |path, px|
      sized = svg.sub(/width="\d+" height="\d+"/, %(width="#{px}" height="#{px}"))
      File.write("/tmp/counta-icon.html",
                 "<style>html,body{margin:0;padding:0}svg{display:block}</style>#{sized}")
      page = browser.create_page
      page.set_viewport(width: px, height: px)
      page.go_to("file:///tmp/counta-icon.html")
      sleep 0.3
      FileUtils.mkdir_p(File.dirname(path))
      page.screenshot(path: path.to_s)
      page.close
      puts "  #{path.relative_path_from(Rails.root)} (#{px}px)"
    end
    browser.quit

    # Record what the PNGs were built from, so a spec can tell when the SVG has
    # moved on without them.
    Rails.root.join("public/icons/SOURCE_SHA").write("#{Digest::SHA256.hexdigest(File.read(SOURCE))}\n")
    puts "rendered from #{SOURCE.relative_path_from(Rails.root)}"
  end
end
