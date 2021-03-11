{ nixos, flake-utils, ... }:
let
    inherit (builtins) attrNames attrValues isAttrs readDir listToAttrs hasAttr mapAttrs pathExists filter;
    
    inherit (nixos.lib) collect fold head length hasSuffix removePrefix removeSuffix nameValuePair
        genList genAttrs optionalAttrs filterAttrs mapAttrs' mapAttrsToList setAttrByPath
        zipAttrsWith zipAttrsWithNames recursiveUpdate nixosSystem mkForce
        substring remove optional foldl' elemAt;
    
    # imports all our dependent libraries
    libImports = let
        gen = v: zipAttrsWith (name: vs: foldl' (a: b: a // b) {} vs) v;
    in gen [ ];

    # if path exists, evaluate expr with it, otherwise return other
    optionalPath = path: expr: other: if builtins.pathExists path then expr path else other;

    # if path exists, import it, otherwise return other
    optionalPathImport = path: other: optionalPath path (p: import p) other;
    
    # mapFilterAttrs ::
    #   (name -> value -> bool )
    #   (name -> value -> { name = any; value = any; })
    #   attrs
    mapFilterAttrs = seive: f: attrs: filterAttrs seive (mapAttrs' f attrs);

    # Generate an attribute set by mapping a function over a list of values.
    genAttrs' = values: f: listToAttrs (map f values);

    # pkgImport :: Nixpkgs -> Overlays -> System -> Pkgs
    pkgImport = nixpkgs: overlays: system: import nixpkgs {
        inherit system overlays;
        config.allowUnfree = true;
    };

    # Convert a list to file paths to attribute set
    # that has the filenames stripped of nix extension as keys
    # and imported content of the file as value.
    pathsToImportedAttrs = paths: let
        paths' = filter (hasSuffix ".nix") paths;
    in
        genAttrs' paths' (path: {
            name = removeSuffix ".nix" (baseNameOf path);
            value = import path;
        });
    
    recImport = { dir, _import ? base: import "${dir}/${base}.nix" }:
        mapFilterAttrs (_: v: v != null) (n: v:
            if n != "default.nix" && hasSuffix ".nix" n && v == "regular" then
                let name = removeSuffix ".nix" n; in nameValuePair (name) (_import name)
            else nameValuePair ("") (null)
        ) (readDir dir);
    
    # recursively merges attribute sets
    recursiveMergeAttrs = attrSets:
    if attrSets == [] then
        {}
    else
        let
            x = head attrSets;
        in x // (recursiveMergeAttrs (remove x attrSets));
    
    # Generates packages for every possible system
    # extern + overlay => { foobar.x86_64-linux }
    genPkgs = root: inputs: let
        inherit (inputs) self;
        inherit (flake-utils.lib) eachDefaultSystem;
    in (eachDefaultSystem (system:
        let
            extern = import (root + "/extern") { inherit inputs; };
            overridePkgs = pkgImport inputs.override [ ] system;
            overridesOverlay = optionalPath (root + "/overrides") (p: (import p).packages) null;

            overlays = (optional (overridesOverlay != null) (overridesOverlay overridePkgs))
            ++ [
                self.overlay
                (final: prev: {
                    # add in our sources
                    srcs = inputs.srcs.inputs;

                    # extend the "lib" namespace with arnix and flake-utils
                    lib = (prev.lib or { }) // {
                        inherit (nixos.lib) nixosSystem;
                        arnix = self.lib or inputs.arnix.lib;
                        flake-utils = flake-utils.lib;
                    };
                })
            ]
            ++ extern.overlays
            ++ self.overlays;
        in { pkgs = pkgImport nixos overlays system; }
    )).pkgs;

    # Generates the "packages" flake output
    # overlay + overlays = packages
    genPackagesOutput = root: inputs: pkgs: let
        inherit (inputs.self) overlay;
        inherit (inputs.self._internal) overlayAttrs;
        
        # grab the package names from all our overlays
        packagesNames = attrNames (overlay null null)
            ++ attrNames (fold (attr: sum: recursiveUpdate sum attr) { } (
                attrValues (mapAttrs (_: v: v null null) overlayAttrs)
            ));
    in fold (key: sum: recursiveUpdate sum {
        "${key}" = pkgs.${key};
    }) { } packagesNames;
    
    genAttrsFromPaths = paths: recursiveMergeAttrs (map (p: setAttrByPath p.name p.value) paths);

    /**
    Synopsis: mkProfileAttrs _path_

    Recursively import the subdirs of _path_ containing a default.nix.

    Example:
    let profiles = mkProfileAttrs ./profiles; in
    assert profiles ? core.default; 0
    **/
    mkProfileAttrs = dir: let
        imports = let
            files = readDir dir;
            p = n: v: v == "directory" && n != "profiles";
        in filterAttrs p files;

        f = n: _: optionalAttrs (pathExists "${dir}/${n}/default.nix") {
            default = "${dir}/${n}";
        } // mkProfileAttrs "${dir}/${n}";
    in mapAttrs f imports;

    # mkProfileDefaults = profiles: let
    #     defaults = collect (x: x ? default) profiles;
    # in map (x: x.default) defaults;

    # shared repo creation function
    mkArnixRepo = root: inputs: let
        inherit (flake-utils.lib)
            eachDefaultSystem flattenTreeSystem;

        # list of module paths -> i.e. security/sgx
        # too bad we cannot output actual recursive attribute sets :(
        moduleAttrs = paths: genAttrs' paths (path: {
            name = removePrefix "${toString (root + "/modules")}/" (toString path);
            value = import path;
        });

        outputs = rec {
            # shared library functions
            lib = if (inputs ? lib) then inputs.lib
                else optionalPathImport (root + "/lib") { };

            # this represents the packages we provide
            overlay = optionalPathImport (root + "/pkgs") (final: prev: {});
            overlays = attrValues _internal.overlayAttrs;

            # attrs of all our nixos modules
            nixosModules = let
                cachix = optionalPath (root + "/cachix.nix")
                    (p: { cachix = import (root + "/cachix.nix"); }) { };
                modules = optionalPath (root + "/modules/module-list.nix")
                    (p: moduleAttrs (import p)) { };
            in recursiveUpdate cachix modules;

            users = optionalPath (root + "/users") (p: mkProfileAttrs (toString p)) { };
            profiles = optionalPath (root + "/profiles") (p: (mkProfileAttrs (toString p))) { };

            # Internal outputs used only for passing to other Arnix repos
            _internal = {
                # import the external input file
                extern = optionalPath (root + "/extern") (p: import p { inherit inputs; }) { };

                # imports all the overlays inside the "overlays" directory
                overlayAttrs = let
                    overlayDir = root + "/overlays";
                in optionalPath overlayDir (p:
                    let
                        fullPath = name: p + "/${name}";
                    in pathsToImportedAttrs (
                        map fullPath (attrNames (readDir p))
                    )
                ) { };
            };
        };

        # Generate per-system outputs
        # i.e. x86_64-linux, aarch64-linux
        systemOutputs = eachDefaultSystem (system: let
            pkgs = (genPkgs root inputs).${system};
        in {
            packages = flattenTreeSystem system (genPackagesOutput root inputs pkgs);

            # WTF is this shit supposed to do?
            #legacyPackages.hmActivationPackages =
            #    genHomeActivationPackages { inherit self; };
        });
    in recursiveUpdate outputs systemOutputs;
in rec {
    # setup is as follows:
    # personal repo -> this repo
    # colmena hives -> arctarus repo -> this repo

    # all repos are merged together to produce a
    # resultant set of modules, profiles, packages, users, and library functions
    # hosts are configured at the top level only
    inherit mapFilterAttrs genAttrs' pathsToImportedAttrs recImport;

    # counts the number of attributes in a set
    attrCount = set: length (attrNames set);

    # given a list of attribute sets, merges the keys specified by "names" from "defaults" into them if they do not exist
    defaultSetAttrs = sets: names: defaults: (mapAttrs' (n: v: nameValuePair n (
        v // genAttrs names (name: (if hasAttr name v then v.${name} else defaults.${name}) )
    )) sets);

    # maps attrs to list with an extra i iteration parameter
    imapAttrsToList = f: set: (
    let
        keys = attrNames set;
    in
    genList (n:
        let
            key = elemAt keys n;
            value = set.${key};
        in 
        f n key value
    ) (length keys));

    # determines whether a given address is IPv6 or not
    isIPv6 = str: builtins.match ".*:.*" str != null;

    # filters out empty strings and null objects from a list
    filterListNonEmpty = l: (filter (x: (x != "" && x != null)) l);

    # converts nix files in directory to name/value pairs
    nixFilesIn = dir: mapAttrs' (name: value: nameValuePair (removeSuffix ".nix" name) (import (dir + "/${name}")))
        (filterAttrs (name: _: hasSuffix ".nix" name)
        (builtins.readDir dir));

    # if condition, then return the value, else an empty list
    optionalList = cond: val: if cond then val else [];

    # Constructs a semantic version string from a derivation
    mkVersion = src: "${substring 0 8 src.lastModifiedDate}_${src.shortRev}";

    # Reduces profile defaults into their parent attributes
    mkProfileDefaults = profiles: (map (profile: profile.default)) profiles;

    # Produces flake outputs for the root repository
    mkRootArnixRepo = mkArnixRepo ./..;

    # Produces flake outputs for intermediate repositories
    mkIntermediateArnixRepo = root: parent: inputs: let
        repo = mkArnixRepo root inputs;
        merged = (zipAttrsWithNames ["lib" "nixosModules" "profiles" "users" "_internal"] (
            name: vs: builtins.foldl' (a: b: recursiveUpdate a b) { } vs
        ) [ parent repo ]);
    in {
        # bring together our overlays with our parent's
        inherit (repo) overlay;
        overlays = [parent.overlay] ++ parent.overlays ++ repo.overlays;
    } // merged;

    # Produces flake outputs for the top-level repository
    mkTopLevelArnixRepo = root: parent: inputs: let
        system = "x86_64-linux";
        extern = import ./../extern { inherit inputs; };  

        # build the repository      
        repo = mkIntermediateArnixRepo root parent inputs;
        pkgs = (genPkgs root inputs).${system};
    in repo // rec {
        nixosConfigurations = import ./hosts.nix (recursiveUpdate inputs {
            inherit pkgs root system extern;
            inherit (pkgs) lib;
            inherit (inputs) arnix;
        });
    };

    # Makes Colmena-compatible flake outputs
    mkColmenaHive = root: parent: inputs: let
        system = "x86_64-linux";
        extern = import ./../extern { inherit inputs; };  

        # build the repository      
        repo = mkIntermediateArnixRepo root parent inputs;
        pkgs = (genPkgs root inputs).${system};
    in repo // rec {

    };
} // libImports
