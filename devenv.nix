{ pkgs, lib, config, ... }:

let
  root = builtins.toString ./.;
in
{
  env.DATABASE_URL = "postgres://manifold_dev:manifold_dev@localhost/manifold_dev?socket_dir=${config.env.DEVENV_RUNTIME}/postgres";
  env.TEST_DATABASE_URL = "postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=${config.env.DEVENV_RUNTIME}/postgres";
  env.PGHOST = "${config.env.DEVENV_RUNTIME}/postgres";
  env.POSTGRES_SOCKET_DIR = "${config.env.DEVENV_RUNTIME}/postgres";

  env.MANIFOLD_SMTP_HOSTNAME = "localhost";
  env.MANIFOLD_SMTP_BIND = "127.0.0.1";
  env.MANIFOLD_SMTP_PORT = "2525";
  env.MANIFOLD_SPOOL_DIR = "${root}/priv/spool/dev";
  env.MANIFOLD_RAW_STORE_BACKEND = "local";
  env.MANIFOLD_RAW_STORE_DIR = "${root}/priv/raw_store/dev";
  env.PHX_HOST = "localhost";
  env.PORT = "4290";
  env.API_PORT = "4292";

  packages = with pkgs; [
    git
    gnumake
    gcc
    openssl
    pkg-config
    postgresql_16
    beam28Packages.elixir-ls
  ] ++ lib.optionals stdenv.isLinux [
    inotify-tools
  ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs.beam28Packages.elixir;

  languages.javascript.enable = true;
  languages.javascript.package = pkgs.nodejs_24;

  services.postgres = {
    enable = true;
    package = pkgs.postgresql_16;
    listen_addresses = "";
    initialDatabases = [
      {
        name = "manifold_dev";
        user = "manifold_dev";
        pass = "manifold_dev";
      }
      {
        name = "manifold_test";
        user = "manifold_dev";
        pass = "manifold_dev";
      }
    ];
    initialScript = "ALTER ROLE manifold_dev CREATEDB;";
  };

  # Load optional `.env` at process/shell start (not via dotenv.enable) so
  # OAuth client secrets stay out of the nix store. See .env.example.
  processes.manifold = {
    exec = ''
      if [ -f .env ]; then
        set -a
        # shellcheck disable=SC1091
        . ./.env
        set +a
      fi
      mix ecto.migrate && mix manifold.run
    '';
    after = [ "devenv:processes:postgres" ];
    ready.http.get = {
      port = 4290;
      path = "/";
    };
  };

  scripts.manifold-setup.exec = ''
    mix setup
  '';

  scripts.manifold-migrate.exec = ''
    mix ecto.migrate
  '';

  scripts.manifold-test.exec = ''
    mix test
  '';

  scripts.manifold-server.exec = ''
    if [ -f .env ]; then
      set -a
      # shellcheck disable=SC1091
      . ./.env
      set +a
    fi
    mix manifold.run
  '';

  enterShell = ''
    echo "Manifold devenv ready"
    echo "PostgreSQL socket: $PGHOST"
    if [ -f .env ]; then
      set -a
      # shellcheck disable=SC1091
      . ./.env
      set +a
      echo "Loaded .env (connector OAuth vars if set)"
    else
      echo "No .env yet — copy .env.example to enable Gmail/Microsoft connectors"
    fi
  '';
}
