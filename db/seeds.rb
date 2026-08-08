# Product reference data, ported from assets/counta-prototype.html PRESETS.
# Idempotent — safe to run repeatedly in every environment.
# counter_style per docs/design-notes.md: Wegovy's window is binary (progress);
# insulin FlexTouch windows show real numbers (numeric).
# Click ratios say "verify per product" in the design notes — these are the
# prototype's working values.
#
# `plan_presets` (issue #21) are transcription aids, never applied to a pen
# automatically: the app defaults to "no plan" and the user picks one. Each
# carries the document it was copied from and the date that document was last
# checked, because a claim about someone's medicine should say where it came
# from. counta's plan features are calibrated to the **Australian** product
# information and the UI says so; the US label differs on missed doses and on
# what several missed doses mean, so a single paraphrase would be wrong in one
# of them and counta paraphrases neither.
#
# The ladder stops at 2.4 mg on purpose. The AU PI's higher 7.2 mg maintenance
# dose is "3 injections of 2.4 mg" — not a dial position, and 222 clicks is
# past the pen's 74-click dial limit. Multi-injection dosing is on the
# anti-roadmap in docs/design-notes.md.
wegovy_au_escalation = {
  key: "wegovy-au-escalation",
  label: "Novo Nordisk published escalation",
  source: {
    # The canonical Australian record. Deliberately the eBS PI locator for the
    # product rather than a deep link to one rendered PDF: the document id
    # changes with each revision, and a citation that 404s is worse than one
    # that needs a click.
    url: "https://www.ebs.tga.gov.au/ebs/picmi/picmirepository.nsf/PICMI?OpenForm&t=PI&q=wegovy",
    label: "TGA product information, revised 22 Jun 2026",
    verified_on: "2026-06-22"
  },
  # `source_label` is quoted from the PI's own dose-escalation table so the UI
  # can show week wording without ever computing a week number from the
  # calendar — the week text is provenance, not a claim about this user.
  steps: [
    { units: 0.25, doses: 4, source_label: "Weeks 1–4" },
    { units: 0.5,  doses: 4, source_label: "Weeks 5–8" },
    { units: 1,    doses: 4, source_label: "Weeks 9–12" },
    { units: 1.7,  doses: 4, source_label: "Weeks 13–16" },
    # Open-ended: the maintenance dose has no end date, and `doses: null` is
    # also how a deliberate hold on any step is expressed.
    { units: 2.4,  doses: nil, source_label: "From week 17" }
  ]
}.freeze

[
  {
    id: "wegovy24", name: "Wegovy", strength: "2.4 mg", unit: "mg", decimals: 2,
    counter_style: "progress",
    capacity_label: "4 doses · 9.6 mg · 3 mL", capacity_units: 9.6, capacity_ml: 3, total_clicks: 296,
    max_dial_clicks: 74, common_doses: [ 0.25, 0.5, 1, 1.7, 2.4 ], default_freq_days: 7,
    plan_presets: [ wegovy_au_escalation ],
    theme: { "--c-body": "#F2F1EE", "--c-body-dark": "#D9D8D4", "--c-accent": "#7FD1C8",
             "--c-label": "#FFFFFF", "--c-text": "#123B6D", "--c-liquid": "#F2FAF9",
             "--c-button": "#C9C8C4", "--c-button-detail": "#8F8E8A" }
  },
  {
    id: "fiasp", name: "Fiasp", strength: "100 U/mL", unit: "U", decimals: 0,
    counter_style: "numeric",
    capacity_label: "3 mL · 300 U", capacity_units: 300, capacity_ml: 3, total_clicks: 300,
    max_dial_clicks: 80, common_doses: [ 2, 4, 6, 8, 10 ], default_freq_days: 1,
    theme: { "--c-body": "#E65300", "--c-body-dark": "#C24400", "--c-accent": "#F7C948",
             "--c-label": "#FFFDF5", "--c-text": "#1B3A6B", "--c-liquid": "#EAF4FB",
             "--c-button": "#E65300", "--c-button-detail": "#B03A12" }
  },
  {
    id: "novorapid", name: "NovoRapid", strength: "100 U/mL", unit: "U", decimals: 0,
    counter_style: "numeric",
    capacity_label: "3 mL · 300 U", capacity_units: 300, capacity_ml: 3, total_clicks: 300,
    max_dial_clicks: 80, common_doses: [ 2, 4, 6, 8, 10 ], default_freq_days: 1,
    theme: { "--c-body": "#E8E5DF", "--c-body-dark": "#C9C5BD", "--c-accent": "#F08A24",
             "--c-label": "#FFFFFF", "--c-text": "#1B3A6B", "--c-liquid": "#EAF4FB",
             "--c-button": "#F08A24", "--c-button-detail": "#B85F0D" }
  },
  {
    id: "tresiba", name: "Tresiba", strength: "200 U/mL", unit: "U", decimals: 0,
    counter_style: "numeric",
    capacity_label: "3 mL · 600 U", capacity_units: 600, capacity_ml: 3, total_clicks: 300,
    max_dial_clicks: 80, common_doses: [ 10, 20, 30, 40 ], default_freq_days: 1,
    theme: { "--c-body": "#2E5E4E", "--c-body-dark": "#204437", "--c-accent": "#9CD5C5",
             "--c-label": "#FBFFFD", "--c-text": "#123B2E", "--c-liquid": "#EAF4FB",
             "--c-button": "#2E5E4E", "--c-button-detail": "#16332A" }
  }
].each do |attrs|
  product = Product.find_or_initialize_by(id: attrs[:id])
  product.update!(attrs.except(:id))
end
