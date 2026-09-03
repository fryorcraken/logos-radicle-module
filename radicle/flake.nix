{
  description = "Minimal Logos Module - Example using logos-module-builder";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/0bc123bb350fb7cbbe7375225b7f8bd8a44f92e8";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
