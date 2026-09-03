{
  description = "Radicle core module — seed-node and local-node repository access";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/0.2.6";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
      tests = {
        dir = ./tests;
      };
    };
}
