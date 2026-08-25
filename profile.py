"""QUIC proxy comparison lab -- Envoy vs nginx vs HAProxy in front of Online Boutique.

CloudLab only reads a profile named `profile.py` from the TOP LEVEL of the
repository, which is why this file lives at the repo root rather than next to
the lab it describes. The lab itself is in cilium-kubernetes-basic/quic-lab/;
see cilium-kubernetes-basic/docs/cloudlab-runbook.md to run it.

Four bare-metal nodes on one untagged LAN:

    node0  10.10.1.1  kubernetes control plane (kubeadm + Cilium)
    node1  10.10.1.2  proxy tier   (envoy / nginx / haproxy, hostNetwork)
    node2  10.10.1.3  app tier     (QUIC origin + Online Boutique)
    node3  10.10.1.4  load generator (outside the cluster, Docker only)

Deliberately NO lan.bandwidth setting: asking CloudLab for a specific bandwidth
inserts a shaping/delay node into the path, which would add jitter and
invalidate every QUIC latency number this lab produces. Unset means native line
rate with no interposed node.
"""
import geni.portal as portal
import geni.rspec.pg as rspec

pc = portal.Context()
request = pc.makeRequestRSpec()

pc.defineParameter(
    "nodeType", "Hardware type",
    portal.ParameterType.NODETYPE, "c6525-25g",
    longDescription="Must exist at the cluster you instantiate at. "
                    "Utah: c6525-25g, xl170, m510. Wisconsin: c220g5, c240g5. "
                    "Clemson: c6420, r650. Check availability before picking.")
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

# The repository is cloned to /local/repository on every node, so the prep
# script is addressed from the repo root -- not from the quic-lab directory.
PREP = ("/local/repository/cilium-kubernetes-basic/quic-lab/cloudlab/"
        "01-node-prep.sh")

for i, (name, role) in enumerate(ROLES):
    node = request.RawPC(name)
    node.hardware_type = params.nodeType
    node.disk_image = params.osImage

    iface = node.addInterface("if0")
    iface.addAddress(rspec.IPv4Address("10.10.1.%d" % (i + 1), "255.255.255.0"))
    lan.addInterface(iface)

    # Invoked through `bash` explicitly rather than relying on the executable
    # bit, which is not reliably preserved when the repo is authored on Windows.
    node.addService(rspec.Execute(
        shell="bash",
        command="bash %s %s > /local/logs/prep.log 2>&1" % (PREP, role)))

pc.printRequestRSpec(request)
