{
  description = "Radicle UI — QML view over the radicle core module";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/0bc123bb350fb7cbbe7375225b7f8bd8a44f92e8";
    radicle.url = "path:../radicle";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
