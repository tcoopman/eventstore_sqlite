# Used by "mix format"
locals_without_parens = [live_eventstore: 1, live_eventstore: 2]

[
  import_deps: [:phoenix, :phoenix_live_view],
  plugins: [Styler],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,dev}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
