# frozen_string_literal: true

require_relative "lib/activerecord/summarize/version"

Gem::Specification.new do |spec|
  spec.name = "activerecord-summarize"
  spec.version = ActiveRecord::Summarize::VERSION
  spec.authors = ["Joshua Paine"]
  spec.email = ["joshua@letterblock.com"]

  spec.summary = "Run many .count and/or .sum queries in a single efficient query with minimal code changes, even with different .group and only-partly-overlapping .where filters. Nearly-free speedups for mature Rails apps."
  spec.description = "Just wrap your existing code in `@relation.summarize do |relation| ... end` and run your queries against relation instead of @relation."
  spec.homepage = "https://letterblock.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/midnightmonster/activerecord-summarize"
  spec.metadata["changelog_uri"] = "https://github.com/midnightmonster/activerecord-summarize/blob/master/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:test|spec|features)/|\.(?:git|travis|circleci|vscode|standard)|appveyor)})
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"
  spec.add_runtime_dependency "activerecord", ">= 5.0"
  spec.add_development_dependency "rake"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
