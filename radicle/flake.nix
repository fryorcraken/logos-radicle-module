{
  description = "Minimal Logos Module - Example using logos-module-builder";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/0.2.6";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
