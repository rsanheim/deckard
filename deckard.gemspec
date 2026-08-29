# frozen_string_literal: true

require_relative "lib/deckard/version"

Gem::Specification.new do |spec|
  spec.name = "deckard"
  spec.version = Deckard::VERSION
  spec.authors = ["Rob Sanheim"]
  spec.email = ["rsanheim@gmail.com"]

  spec.summary = "TODO: Write a short summary, because RubyGems requires one."
  spec.description = "TODO: Write a longer description or delete this line."
  spec.homepage = "https://github.com/rsanheim/deckard"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rsanheim/deckard"

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  # spec.metadata["rubygems_mfa_required"] = "true"

  # Ship only the library, executable, and top-level docs. A plain glob (not
  # `git ls-files`) so the gem also resolves as a path dependency in contexts
  # without a .git directory, such as the harness docker image.
  spec.files = Dir.glob(%w[lib/**/*.rb exe/* README.md], base: __dir__)
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 8.0", "< 9.0"
  spec.add_dependency "optimist", "~> 3.2"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
