# Builds a NixNet experiment that runs one gobgpd per router of `topology`
# (see ./topology.nix) on a full mesh of point-to-point links, with one eBGP
# session per link, and measures whether the routers agree on a stable best
# path for a prefix announced by the origin router.
#
# `obgp` selects the variant under test: with true the daemons run with
# GOBGP_OPERA_ENABLED=true (OBGP), with false they are plain GoBGP.
#
# Returns { config, configs } where `config` is the NixNet module for
# mkExperiment and `configs.<router>` is the rendered gobgpd configuration.
{
  pkgs,
  lib,
  gobgp,
  topology,
  obgp ? false,
  originPrefix ? "10.99.0.0/24",
  sampleInterval ? 0.25,
  sampleDuration ? 30,
  holdTime ? 9,
  keepaliveInterval ? 3,
  connectRetry ? 2,
}:
let
  routers = topology.routers;
  names = lib.attrNames routers;
  origins = topology.roles.origins;
  nNodes = lib.length names;

  # Address plan: every neighbor pair is one point-to-point link. The link
  # index (deterministically the position of the pair in the sorted list of
  # links) picks the /24, the lexicographically smaller router of the pair
  # gets .1, the larger one .2.
  linkId = a: b: if a < b then "${a}-${b}" else "${b}-${a}";
  links = lib.sort (a: b: a < b) (
    lib.unique (lib.concatMap (name: map (n: linkId name n.name) routers.${name}.neighbors) names)
  );
  linkIndex = lib.listToAttrs (lib.imap0 (i: l: lib.nameValuePair l i) links);
  linkEnds = lib.listToAttrs (
    lib.concatMap (
      name:
      map (
        n:
        lib.nameValuePair (linkId name n.name) (
          if name < n.name then
            {
              a = name;
              b = n.name;
            }
          else
            {
              a = n.name;
              b = name;
            }
        )
      ) routers.${name}.neighbors
    ) names
  );
  ifaceOf = l: "e${toString (linkIndex.${l} + 1)}";
  linkSubnet = l: "10.10.${toString (linkIndex.${l} + 1)}";
  # Address of router `a` on the link it shares with router `b`.
  addressOf = a: b: "${linkSubnet (linkId a b)}.${if a < b then "1" else "2"}";
  # Address of a neighbor as seen from the router that has it configured.
  peerAddressOf = name: n: addressOf n.name name;

  # A neighbor entry of one router needs the mirrored entry on the other, or
  # the peer has no interface on the link both sides are addressed on.
  symmetry = lib.concatMap (
    name:
    map (n: {
      assertion = lib.any (m: m.name == name) routers.${n.name}.neighbors;
      message = "topology: ${name} lists ${n.name} as neighbor, but ${n.name} does not list ${name}";
    }) routers.${name}.neighbors
  ) names;

  renderConfig =
    name:
    let
      r = routers.${name};
      preferred = lib.filter (n: n ? localPref) r.neighbors;
      neighborSets = lib.concatMapStrings (n: ''
        [[defined-sets.neighbor-sets]]
          neighbor-set-name = "${n.name}"
          neighbor-info-list = ["${peerAddressOf name n}"]

        [[policy-definitions]]
          name = "lp-${n.name}"
          [[policy-definitions.statements]]
            [policy-definitions.statements.conditions.match-neighbor-set]
              neighbor-set = "${n.name}"
            [policy-definitions.statements.actions]
              route-disposition = "accept-route"
            [policy-definitions.statements.actions.bgp-actions]
              set-local-pref = ${toString n.localPref}

      '') preferred;
      neighbors = lib.concatMapStrings (n: ''
        [[neighbors]]
          [neighbors.config]
            neighbor-address = "${peerAddressOf name n}"
            peer-as = ${toString n.peerAs}
          [neighbors.timers.config]
            hold-time = ${toString holdTime}
            keepalive-interval = ${toString keepaliveInterval}
            connect-retry = ${toString connectRetry}
            idle-hold-time-after-reset = ${toString connectRetry}
          [neighbors.transport.config]
            passive-mode = ${lib.boolToString (n.peerAs > r.asn)}
          [[neighbors.afi-safis]]
            [neighbors.afi-safis.config]
              afi-safi-name = "ipv4-unicast"

      '') r.neighbors;
    in
    ''
      # ${name}: AS${toString r.asn}, router-id ${r.routerId}
      # Generated from ./topology.nix. OBGP is selected by the environment
      # variable GOBGP_OPERA_ENABLED, not by this file.
      [global.config]
        as = ${toString r.asn}
        router-id = "${r.routerId}"

      ${neighborSets}
      [global.apply-policy.config]
        import-policy-list = [${lib.concatStringsSep ", " (map (n: ''"lp-${n.name}"'') preferred)}]
        default-import-policy = "accept-route"
        export-policy-list = []
        default-export-policy = "accept-route"

      ${neighbors}
    '';

  configFiles = lib.mapAttrs (name: _: pkgs.writeText "gobgpd-${name}.conf" (renderConfig name)) routers;

  # Every router samples its own best path for the observed prefix; a router
  # whose best path keeps changing is oscillating. The origin announces the
  # prefix two seconds into the sampling window, after a wall-clock barrier
  # that lines all routers up on the same instant.
  nodeMain = name: ''
    n_neighbors=${toString (lib.length routers.${name}.neighbors)}

    until gobgp neighbor > neighbor.log 2>/dev/null; do sleep 0.2; done
    while [ "$(grep -c Establ neighbor.log || true)" -lt "$n_neighbors" ]; do
      sleep 0.2
      gobgp neighbor > neighbor.log
    done
    echo "all $n_neighbors sessions established"

    t0=$(( ($(date +%s) / 10 + 1) * 10 ))
    while [ "$(date +%s)" -lt "$t0" ]; do sleep 0.05; done

    # "<number of paths in the Loc-RIB> <best path as next-hop + AS path>".
    #
    # The API's "best" flag is not filled in by this fork's ListPath (it is
    # false for every path), so the best path is taken as the first entry: the
    # Loc-RIB keeps its paths sorted most preferred first. JSON, so that age
    # and attributes, which change on every sample, stay out of the key.
    best() {
      local out
      out=$(
        gobgp -j global rib -a ipv4 ${originPrefix} 2>/dev/null |
          jq -r '[ .[] | .[] ] as $paths
                 | (($paths | length | tostring) + " "
                    + (if ($paths | length) == 0 then "-"
                       else ($paths[0]
                             | (([.attrs[] | select(.type == 3) | .nexthop][0] // "no-nexthop")
                                + " "
                                + ([.attrs[] | select(.type == 2) | .as_paths[] | .asns[]] | join(" "))))
                       end))' 2>/dev/null
      ) || out=""
      printf '%s' "''${out:-- -}"
    }
    ${lib.optionalString (lib.elem name origins) ''
      # Two seconds into the sampling window, without shortening it.
      ( sleep 2; gobgp global rib add ${originPrefix}; echo "originated ${originPrefix}" ) &
    ''}
    : > rib.log
    gobgp global rib -a ipv4 ${originPrefix} > rib-raw.log 2>&1 || true

    end=$(( t0 + ${toString sampleDuration} ))
    while [ "$(date +%s)" -le "$end" ]; do
      printf '%s %s\n' "$(date +%s.%N)" "$(best)" >> rib.log
      sleep ${toString sampleInterval}
    done
    echo "sampled $(wc -l < rib.log) times"
    : > done
  '';

  nodeScripts = name: {
    # The daemon runs in the background for the whole experiment.
    daemon = {
      exec = ''
        cp ${configFiles.${name}} gobgpd.conf
        export GOBGP_OPERA_ENABLED=${if obgp then "true" else "false"}
        echo "gobgpd AS${toString routers.${name}.asn} router-id ${routers.${name}.routerId} OBGP=$GOBGP_OPERA_ENABLED"
        exec gobgpd -f gobgpd.conf --api-hosts 127.0.0.1:50051 --log-plain
      '';
    };
    main = {
      exec = nodeMain name;
      await = true;
    };
  };

  variant = if obgp then "obgp" else "bgp";
in
{
  configs = lib.mapAttrs (_: renderConfig) routers;

  config = {
    name = "gobgp-${variant}-${lib.replaceStrings [ "/" "." ] [ "_" "_" ] originPrefix}";

    nodes = lib.genAttrs names (name: {
      packages = [
        gobgp
        pkgs.jq
      ];

      networking.interfaces = lib.listToAttrs (
        map (n: {
          name = ifaceOf (linkId name n.name);
          value.ipv4.addresses = [
            {
              address = addressOf name n.name;
              prefixLength = 24;
            }
          ];
        }) routers.${name}.neighbors
      );

      scripts = nodeScripts name;
    });

    # The attribute key is the link, not an interface name: both endpoints get
    # the interface name of their link (`e1` … `e6`), each inside its own node.
    veths = lib.mapAttrs (l: ends: {
      a.node = ends.a;
      a.iface = ifaceOf l;
      b.node = ends.b;
      b.iface = ifaceOf l;
    }) linkEnds;

    scripts.report = {
      await = true;
      exec = ''
        nodes="${lib.concatStringsSep " " names}"
        for _ in $(seq 1 600); do
          [ "$(ls */done 2>/dev/null | wc -l)" -eq ${toString nNodes} ] && break
          sleep 0.5
        done

        echo
        echo "${if obgp then "OBGP" else "plain GoBGP"}: best path and Loc-RIB size for ${originPrefix}, sampled every ${toString sampleInterval}s over ${toString sampleDuration}s"
        printf '%-11s %7s %8s %7s %16s %6s  %s\n' router samples changes states "paths min/avg/max" known "path (last | distinct, in order)"
        for node in $nodes; do
          if [ ! -s "$node/rib.log" ]; then
            printf '%-11s %7s\n' "$node" "no data"
            continue
          fi
          # `known` and the size statistics count only the samples in which the
          # prefix is in the Loc-RIB, i.e. after the origin announced it.
          awk -v node="$node" '
            {
              paths = $2
              p = $3
              for (i = 4; i <= NF; i++) p = p " " $i
              if (NR > 1 && p != prev) changes++
              if (!(p in seen)) { seen[p] = 1; states++; order = order (order ? " | " : "") p }
              prev = p
              samples++
              final = p
              if (paths > 0) {
                known++
                sum += paths
                if (known == 1 || paths < min) min = paths
                if (known == 1 || paths > max) max = paths
              }
            }
            END {
              printf "%-11s %7d %8d %7d %6d/%6.1f/%5d %6d  %s | %s\n",
                node, samples, changes, states, min, sum / known, max, known, final, order
            }
          ' "$node/rib.log"
        done

        echo
        echo "per router: <router>/rib.log (samples), <router>/rib-raw.log (first RIB dump), <router>/gobgpd.conf"
      '';
    };

    assertions = symmetry;
  };
}
