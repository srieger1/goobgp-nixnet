# The BAD GADGET topology of the OBGP lab, ported from
# gobgp-lab/topologies/bad-gadget.yaml of Stinktopf/gobgp (branch obgp-fixes).
#
# Four routers, one eBGP session per pair (6 links), and a cyclic preference
# order: frankfurt prefers routes learned from fulda, toronto those from
# frankfurt, fulda those from toronto. That cycle is what makes plain BGP
# oscillate on the BAD GADGET (Griffin & Wilfong), and what OBGP's strict
# import/export ordering is supposed to prevent.
{
  # Routers that originate the prefix the experiment announces.
  roles.origins = [ "aachen" ];

  routers = {
    frankfurt = {
      asn = 65001;
      routerId = "10.0.0.1";
      neighbors = [
        {
          name = "toronto";
          peerAs = 65002;
        }
        {
          name = "fulda";
          peerAs = 65003;
          localPref = 200;
        }
        {
          name = "aachen";
          peerAs = 65004;
        }
      ];
    };

    toronto = {
      asn = 65002;
      routerId = "10.0.0.2";
      neighbors = [
        {
          name = "frankfurt";
          peerAs = 65001;
          localPref = 200;
        }
        {
          name = "fulda";
          peerAs = 65003;
        }
        {
          name = "aachen";
          peerAs = 65004;
        }
      ];
    };

    fulda = {
      asn = 65003;
      routerId = "10.0.0.3";
      neighbors = [
        {
          name = "frankfurt";
          peerAs = 65001;
        }
        {
          name = "toronto";
          peerAs = 65002;
          localPref = 200;
        }
        {
          name = "aachen";
          peerAs = 65004;
        }
      ];
    };

    aachen = {
      asn = 65004;
      routerId = "10.0.0.4";
      neighbors = [
        {
          name = "frankfurt";
          peerAs = 65001;
        }
        {
          name = "toronto";
          peerAs = 65002;
        }
        {
          name = "fulda";
          peerAs = 65003;
        }
      ];
    };
  };
}
