{ directory # corresponds to notebook_dir (impure)
, overlays ? []
, config ? {}
, pkgs ? import ./nix { inherit config overlays; }
, labextensions ? []
, serverextensions ? (_:[])
}:

with (import ./lib/directory.nix { inherit pkgs; });
with (import ./lib/docker.nix { inherit pkgs; });
with builtins;
with pkgs.lib;
with pkgs.lib.strings;

let
  # Kernel generators.
  kernels = pkgs.callPackage ./kernels {};
  kernelsString = concatMapStringsSep ":" (k: "${k.spec}");

  # Python version setup.
  python3 = pkgs.python3Packages;

  # Default configuration.
  defaultKernels = [ (kernels.iPythonWith {}) ];
  defaultExtraPackages = p: [];

  shareDirectoryPure = "${python3.jupyterlab}/share/jupyter";

  notebookDirectoryImpure = directory;
  shareDirectoryImpure = "${directory}/share-jupyter";

  serverextensionsPackages = (serverextensions python3);

  # JupyterLab with the appropriate kernel and directory setup.
  jupyterlabWith = {
    directory ? shareDirectoryPure,
    kernels ? defaultKernels,
    extraPackages ? defaultExtraPackages
    }:
    let
      # PYTHONPATH setup for JupyterLab
      pythonPath = python3.makePythonPath ([
        python3.ipykernel
        python3.jupyter_contrib_core
        python3.jupyter_nbextensions_configurator
        python3.tornado
      ] ++
      serverextensionsPackages
      );

      # JupyterLab executable wrapped with suitable environment variables.
      jupyterlab = python3.toPythonModule (
        python3.jupyterlab.overridePythonAttrs (oldAttrs: {
          makeWrapperArgs = [
            # TODO: not sure whether these are all needed
            "--set JUPYTER_CONFIG_DIR \"${shareDirectoryImpure}/config\""
            "--set JUPYTER_DATA_DIR \"${shareDirectoryImpure}/data\""
            "--set JUPYTER_RUNTIME_DIR \"${shareDirectoryImpure}/runtime\""
            "--set JUPYTERLAB_DIR \"${shareDirectoryImpure}/lab\""
            "--set JUPYTER_PATH \"${kernelsString kernels}\""
            "--set PYTHONPATH \"${pythonPath}\""
          ];
        })
      );

      serverextensionPNames = (
        map (p: escapeNixString (attrsets.getAttrFromPath ["pname"] p)) serverextensionsPackages
      );

      serverextensionOutPaths = (
        map (p: escapeNixString (attrsets.getAttrFromPath ["outPath"] p)) serverextensionsPackages
      );

      # Shell with the appropriate JupyterLab, launching it at startup.
      env = pkgs.mkShell {
        name = "jupyterlab-shell";
        buildInputs =
          [ jupyterlab generateDirectory pkgs.nodejs ] ++
          (map (k: k.runtimePackages) kernels) ++
          (extraPackages pkgs);
        shellHook = ''
          # this is needed in order that tools like curl and git can work with SSL
          if [ ! -f "$SSL_CERT_FILE" ] || [ ! -f "$NIX_SSL_CERT_FILE" ]; then
            candidate_ssl_cert_file=""
            if [ -f "$SSL_CERT_FILE" ]; then
              candidate_ssl_cert_file="$SSL_CERT_FILE"
            elif [ -f "$NIX_SSL_CERT_FILE" ]; then
              candidate_ssl_cert_file="$NIX_SSL_CERT_FILE"
            else
              candidate_ssl_cert_file="/etc/ssl/certs/ca-bundle.crt"
            fi
            if [ -f "$candidate_ssl_cert_file" ]; then
                export SSL_CERT_FILE="$candidate_ssl_cert_file"
                export NIX_SSL_CERT_FILE="$candidate_ssl_cert_file"
            else
              echo "Cannot find a valid SSL certificate file. curl will not work." 1>&2
            fi
          fi

          export JUPYTER_PATH="${kernelsString kernels}"
          export JUPYTER_CONFIG_DIR="${shareDirectoryImpure}/config"
          export JUPYTER_DATA_DIR="${shareDirectoryImpure}/data"
          export JUPYTER_RUNTIME_DIR="${shareDirectoryImpure}/runtime"
          export JUPYTERLAB_DIR="${shareDirectoryImpure}/lab"
          export JUPYTERLAB="${jupyterlab}"

          if [ ! -d "${shareDirectoryImpure}" ]; then
            mkdir -p "$JUPYTER_CONFIG_DIR"
            mkdir -p "$JUPYTER_DATA_DIR"
            mkdir -p "$JUPYTER_RUNTIME_DIR"
            mkdir -p "$JUPYTERLAB_DIR"/extensions

            # We need to set notebook_dir in config so that this command:
            #   direnv exec ~/Documents/myenv jupyter lab start
            # always results in notebook_dir being ~/Documents/myenv.
            # If we don't, then running that command from $HOME makes notebook_dir be $HOME.
            if [ -f "$JUPYTER_CONFIG_DIR/jupyter_notebook_config.json" ]; then
              echo "File already exists: $JUPYTER_CONFIG_DIR/jupyter_notebook_config.json" >/dev/stderr
              exit 1
            fi
            echo '{"NotebookApp": {"notebook_dir": "${notebookDirectoryImpure}"}}' >"$JUPYTER_CONFIG_DIR/jupyter_notebook_config.json"
          fi

          for pname in $(echo "${toString serverextensionPNames}"); do
            jupyter serverextension enable "$pname"
          done

          for f in $(echo "${toString serverextensionOutPaths}"); do
            if [ -d "$f"/share/jupyter/lab/extensions ]; then
              cp "$f"/share/jupyter/lab/extensions/*.tgz "$JUPYTERLAB_DIR"/extensions/
            fi
          done

          for labextension in $(echo "${toString labextensions}"); do
            jupyter labextension install "$labextension" --app-dir="$JUPYTERLAB_DIR" --no-build > /dev/null
          done

          chmod -R +w "$JUPYTERLAB_DIR"

          jupyter lab build --app-dir="$JUPYTERLAB_DIR" > /dev/null

          chmod -R +w "$JUPYTERLAB_DIR"

          # TODO: why do I need to build twice for this to work?
          jupyter lab build --app-dir="$JUPYTERLAB_DIR" > /dev/null

          chmod -R +w "$JUPYTERLAB_DIR"/staging
          rm -rf "$JUPYTERLAB_DIR"/staging
        '';
      };
    in
      jupyterlab.override (oldAttrs: {
        passthru = oldAttrs.passthru or {} // { inherit env; };
      });
in
  { inherit jupyterlabWith kernels mkDirectoryWith mkDockerImage; }
