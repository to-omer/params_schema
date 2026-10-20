{
  description = "Nix development environments for Params Schema";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-ruby32.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { nixpkgs, nixpkgs-ruby32, ... }:
    let
      systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ];
    in
    {
      devShells = nixpkgs.lib.genAttrs systems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          legacy = nixpkgs-ruby32.legacyPackages.${system};
          shell = ruby: without:
            let
              # Match the lockfiles; older bundled versions conflict with Nixpkgs' RubyGems.
              bundler = pkgs.buildRubyGem {
                inherit ruby;
                gemName = "bundler";
                version = "4.0.20";
                source.sha256 = "sha256-eXiorGSHZ/XmNbxSJEW3noClK5B6OaNsLYCF7WvHYq4=";
                dontPatchShebangs = true;
              };
            in
            pkgs.mkShell {
              packages = [ bundler ruby pkgs.git pkgs.pinact ];
              BUNDLE_WITHOUT = without;
              shellHook = ''
                export BUNDLE_PATH="$PWD/vendor/bundle"
              '';
            };
        in
        {
          default = shell pkgs.ruby_4_0 "";
          # Nixpkgs' named packages lag these upstream patch releases.
          ruby32 = shell (legacy.mkRuby {
            version = legacy.mkRubyVersion "3" "2" "11" "";
            hash = "sha256-s+6r1mNvM0Ux2z/9wyKesF5SR0DmyE/cBDcgVzzy+LI=";
            cargoHash = "sha256-CMVx5/+ugDNEuLAvyPN0nGHwQw6RXyfRsMO9I+kyZpk=";
          }) "development";
          ruby33 = shell (pkgs.mkRuby {
            version = pkgs.mkRubyVersion "3" "3" "12" "";
            hash = "sha256-sG1jvq4nGTMDPifwo4m8WCoAnnhFNX1ENlw53lJaBRs=";
            cargoHash = "sha256-xE7Cv+NVmOHOlXa/Mg72CTSaZRb72lOja98JBvxPvSs=";
          }) "development";
          ruby34 = shell (pkgs.mkRuby {
            version = pkgs.mkRubyVersion "3" "4" "11" "";
            hash = "sha256-XCK+RFJDErPUM9aHObzFMGM7HaXvi6CvoKN2gNoX094=";
            cargoHash = "sha256-5Tp8Kth0yO89/LIcU8K01z6DdZRr8MAA0DPKqDEjIt0=";
          }) "development";
          ruby40 = shell pkgs.ruby_4_0 "development";
        });
    };
}
