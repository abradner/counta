# Attribution links (alexbradner.com, the source repo) are rendered once by
# a shared partial (app/views/home/_attribution.html.erb) outside every
# hidden screen section, so the same markup shows on the signed-out landing
# surface and on the signed-in app screen without being duplicated per
# screen (AGENTS.md §8 "shared partial is fine if that's cleanest").
require "rails_helper"

RSpec.describe "Attribution footer", type: :system do
  def expect_attribution_links
    within("footer.attribution") do
      site_link = find_link("Alex Bradner")
      # Browsers normalise a bare-domain href to include the root path.
      expect(site_link[:href]).to eq("https://alexbradner.com/")
      expect(site_link[:target]).to eq("_blank")
      expect(site_link[:rel]).to eq("noopener noreferrer")

      repo_link = find_link("counta source on GitHub")
      expect(repo_link[:href]).to eq("https://github.com/abradner/counta")
      expect(repo_link[:target]).to eq("_blank")
      expect(repo_link[:rel]).to eq("noopener noreferrer")
    end
  end

  it "shows attribution links on the signed-out landing surface" do
    visit "/"
    expect(page).to have_button("Create account") # positive control: landing rendered
    expect_attribution_links
  end

  it "keeps showing the same attribution links once signed in, on the app screen" do
    load Rails.root.join("db/seeds.rb") # products must exist for setup to render (app.js)
    visit "/"
    add_virtual_authenticator
    sign_up_through_first_run

    expect(page).to have_css("#setup-card", visible: :visible)
    expect_attribution_links
  end
end
