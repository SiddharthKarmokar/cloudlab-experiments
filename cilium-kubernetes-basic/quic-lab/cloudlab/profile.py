"""QUIC proxy comparison lab.

Four bare-metal nodes on one untagged LAN:

    node0  10.10.1.1  kubernetes control plane
    node1  10.10.1.2  proxy tier   (envoy / nginx / haproxy, hostNetwork)
    node2  10.10.1.3  app tier     (quic origin + Online Boutique)
    node3  10.10.1.4  load generator (outside the cluster)

Deliberately NO lan.bandwidth setting: asking CloudLab for a specific
bandwidth inserts a shaping/delay node into the path, which would add
tens of microseconds of jitter and invalidate every QUIC latency number
this lab produces. Unset == native line rate, no interposed node.
"""
import geni.portal as portal
import geni.rspec.pg as rspec

pc = portal.Context()
request = pc.makeRequestRSpec()

pc.defineParameter(
    "nodeType", "Hardware type",
    portal.ParameterType.NODETYPE, "c6525-25g",
    longDescription="c6525-25g (Utah, 16c/32t, 25GbE) is the default. "
                    "Fallbacks with similar NICs: xl170, c6420, c220g5.")
pc.defineParameter(
    "osImage", "OS image",
    portal.ParameterType.IMAGE,
    "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU24-64-STD",
    longDescription="Ubuntu 24.04 (kernel 6.8) -- needed for a modern eBPF "
                    "surface for Cilium and for UDP GSO/GRO in the QUIC path.")
params = pc.bindParameters()

lan = request.LAN("lan0")
lan.best_effort = True
lan.vlan_tagging = False

ROLES = [
    ("node0", "control"),
    ("node1", "proxy"),
    ("node2", "app"),
    ("node3", "loadgen"),
]

for i, (name, role) in enumerate(ROLES):
    node = request.RawPC(name)
    node.hardware_type = params.nodeType
    node.disk_image = params.osImage

    iface = node.addInterface("if0")
    iface.addAddress(rspec.IPv4Address("10.10.1.%d" % (i + 1), "255.255.255.0"))
    lan.addInterface(iface)

    node.addService(rspec.Execute(
        shell="bash",
        command="/local/repository/quic-lab/cloudlab/01-node-prep.sh %s "
                "> /local/logs/prep.log 2>&1" % role))

pc.printRequestRSpec(request)
