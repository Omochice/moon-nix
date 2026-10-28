# Declarative code generation is a build dependency, never an evaluation input.
{
  pkgs,
  toolchain,
  stdenv,
  nativeBuildInputs,
  prebuildInputs,
}:
package:
let
  inherit (pkgs) lib;
  fail = message: throw "moon-nix prebuild ${package.fqn}: ${message}";
  asList = value: if builtins.isList value then value else [ value ];
  pkgRel = lib.removePrefix (toString package.module.source + "/") (toString package.directory);
  prefix = if toString package.directory == toString package.module.source then "" else pkgRel + "/";
  # moon resolves rule paths against the package and lets `..` reach other parts of the module.
  modulePath =
    path:
    let
      parts = lib.foldl' (
        acc: part:
        if part == "" || part == "." then
          acc
        else if part == ".." then
          if acc == [ ] then fail "path ${path} leaves the module" else lib.init acc
        else
          acc ++ [ part ]
      ) [ ] (lib.splitString "/" (prefix + path));
    in
    if !builtins.isString path || path == "" || lib.hasPrefix "/" path || parts == [ ] then
      fail "invalid path ${toString path}"
    else
      lib.concatStringsSep "/" parts;
  namedRules = asList (package.module.raw.rule or [ ]) ++ asList (package.raw.rule or [ ]);
  names = builtins.listToAttrs (
    map (r: {
      name = r.name;
      value = r.command;
    }) namedRules
  );
  lower =
    legacy: rule:
    let
      paths = value: map modulePath (asList value);
      inputs = paths (rule.input or [ ]);
      outputs = paths (rule.output or [ ]);
      command = rule.command or (names.${rule.rule} or (fail "unknown rule ${rule.rule}"));
    in
    if outputs == [ ] then
      fail "a rule needs declared outputs"
    else
      {
        inherit inputs outputs command;
        packageOutputs = map (
          p:
          if prefix == "" || lib.hasPrefix prefix p then
            lib.removePrefix prefix p
          else
            fail "output ${p} is outside the package"
        ) outputs;
        cwd = if legacy then prefix else "";
      };
  rules =
    map (lower true) (asList (package.raw.pre-build or [ ]))
    ++ map (lower false) (asList (package.raw.dev-build or [ ]));
  indexed = lib.imap0 (index: r: r // { inherit index; }) rules;
  allOutputs = lib.concatMap (r: r.outputs) rules;
  owners = builtins.listToAttrs (
    lib.concatMap (
      r:
      map (output: {
        name = output;
        value = r.index;
      }) r.outputs
    ) indexed
  );
  dependencies =
    r: lib.unique (map (input: owners.${input}) (builtins.filter (input: owners ? ${input}) r.inputs));
  visit =
    index: stack: seen:
    if builtins.elem index stack then
      fail "rule dependency cycle"
    else if builtins.elem index seen then
      seen
    else
      (lib.foldl' (acc: dep: visit dep (stack ++ [ index ]) acc) seen (
        dependencies (builtins.elemAt indexed index)
      ))
      ++ [ index ];
  order =
    if builtins.length (lib.unique allOutputs) != builtins.length allOutputs then
      fail "duplicate generated output"
    else
      lib.foldl' (seen: r: visit r.index [ ] seen) [ ] indexed;
  source = builtins.path {
    path = package.module.source;
    name = package.stem + "-prebuild-source";
    filter =
      path: type:
      type != "directory"
      || !builtins.elem (builtins.baseNameOf path) [
        ".git"
        "_build"
        ".mooncakes"
        "node_modules"
      ];
  };
  derivations = map (
    r:
    let
      parents = map (index: {
        rule = builtins.elemAt indexed index;
        drv = builtins.elemAt derivations index;
      }) (dependencies r);
      replace =
        builtins.replaceStrings
          [ "$mooncake_bin" "$mod_dir" "$pkg_dir" "$input" "$output" ]
          [
            "$MOONCAKE_BIN"
            "$MODULE_DIR"
            "$PACKAGE_DIR"
            (lib.concatMapStringsSep " " (p: ''"$MODULE_DIR"/${lib.escapeShellArg p}'') r.inputs)
            (lib.concatMapStringsSep " " (p: ''"$MODULE_DIR"/${lib.escapeShellArg p}'') r.outputs)
          ];
      command = replace (
        if lib.hasPrefix ":embed " r.command then
          "moon tool embed " + lib.removePrefix ":embed " r.command
        else
          r.command
      );
    in
    pkgs.runCommand "${package.stem}-prebuild-${toString r.index}"
      {
        nativeBuildInputs = [ toolchain ] ++ nativeBuildInputs ++ prebuildInputs package;
        inherit stdenv;
      }
      ''
        cp -r ${source} workspace
        chmod -R u+w workspace
        cd workspace
        export MODULE_DIR="$PWD"
        export PACKAGE_DIR="$PWD"/${lib.escapeShellArg prefix}
        export HOME="$TMPDIR"
        export MOONCAKE_BIN=${
          pkgs.buildEnv {
            name = package.stem + "-prebuild-tools";
            paths = prebuildInputs package;
            pathsToLink = [ "/bin" ];
          }
        }/bin
        ${lib.concatMapStringsSep "\n" (
          parent:
          lib.concatMapStringsSep "\n" (output: ''
            mkdir -p ${lib.escapeShellArg (builtins.dirOf output)}
            cp ${lib.escapeShellArg "${parent.drv}/${output}"} ${lib.escapeShellArg output}
          '') parent.rule.outputs
        ) parents}
        ${lib.concatMapStringsSep "\n" (input: "test -f ${lib.escapeShellArg input}") r.inputs}
        ${lib.concatMapStringsSep "\n" (output: ''
          mkdir -p ${lib.escapeShellArg (builtins.dirOf output)}
          rm -f ${lib.escapeShellArg output}
        '') r.outputs}
        ${lib.optionalString (r.cwd != "") "cd ${lib.escapeShellArg r.cwd}"}
        ${command}
        cd "$MODULE_DIR"
        ${lib.concatMapStringsSep "\n" (output: ''
          test -f ${lib.escapeShellArg output}
          mkdir -p "$out"/${lib.escapeShellArg (builtins.dirOf output)}
          cp ${lib.escapeShellArg output} "$out"/${lib.escapeShellArg output}
        '') r.outputs}
      ''
  ) indexed;
  generated = lib.concatMap (
    r:
    lib.imap0 (i: relative: {
      file = relative;
      path = "${builtins.elemAt derivations r.index}/${builtins.elemAt r.outputs i}";
    }) r.packageOutputs
  ) indexed;
in
builtins.deepSeq order { inherit derivations generated; }
