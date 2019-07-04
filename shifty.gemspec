lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "shifty/version"

Gem::Specification.new do |spec|
  spec.name          = "shifty"
  spec.version       = Shifty::VERSION
  spec.authors       = ["Joel Helbling"]
  spec.email         = ["joel@joelhelbling.com"]

  spec.summary       = "A functional framework aimed at extremely low coupling"
  spec.description   = "Shifty provides tools for coordinating simple workers which consume a supplying queue and emit corresponding work products, valuing pure functions, carefully isolated side effects, and extremely low coupling."
  spec.homepage      = "https://github.com/joelhelbling/shifty"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec", "~> 3.1"
  spec.add_development_dependency "rspec-given", "~> 3.8"
  spec.add_development_dependency "pry"
  spec.add_development_dependency "simplecov"
end
