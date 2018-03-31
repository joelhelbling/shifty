$:.push File.expand_path("../lib", __FILE__)
require 'shifty/version'

Gem::Specification.new do |s|
  s.name = "shifty"
  s.version = Shifty::VERSION
  s.platform = Gem::Platform::RUBY
  s.authors = ["Joel Helbling"]
  s.email = ["joel@joelhelbling.com"]
  s.homepage = "http://github.com/joelhelbling/shifty"
  s.summary = %q{ A ruby-fibers-based framework aimed at extremely low coupling. }
  s.description = %q{ Shifty grew out of experimentation with Ruby fibers, after readings Dave Thomas' demo of Ruby fibers, wherein he created a pipeline of fiber processes, emulating the style and syntax of the *nix command line. I noticed that, courtesy of fibers' extremely low surface area, fiber-to-fiber collaborators could operate with extremely low coupling. That was the original motivation for creating the framework. }

  s.rubyforge_project = "shifty"
  s.files = `git ls-files`.split("\n")
  s.test_files = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  s.add_development_dependency 'rspec',      '3.1.0'
  s.add_development_dependency 'rspec-core', '3.1.2'
  s.add_development_dependency 'rspec-its',  '1.0.1'
  s.add_development_dependency 'rspec-given', '3.8.0'
  s.add_development_dependency 'pry'
end
