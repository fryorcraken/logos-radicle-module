{
  description = "Radicle UI — QML view over the radicle core module";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/0.2.6";
    radicle.url = "path:../radicle";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
