this project forked from https://github.com/trudi-group/ipfs-crawler.git
# Libp2p-Crawler

A crawler for the Kademlia-part of various libp2p networks.

**For more details, see [our paper](https://arxiv.org/abs/2002.07747).**

If you use our work, please **cite our papers**:

Sebastian A. Henningsen, Martin Florian, Sebastian Rust, Björn Scheuermann:
**Mapping the Interplanetary Filesystem.** *Networking 2020*: 289-297\
[[BibTex]](https://dblp.uni-trier.de/rec/conf/networking/HenningsenFR020.html?view=bibtex)

Sebastian A. Henningsen, Sebastian Rust, Martin Florian, Björn Scheuermann:
**Crawling the IPFS Network.** *Networking 2020*: 679-680\
[[BibTex]](https://dblp.uni-trier.de/rec/conf/networking/HenningsenRF020.html?view=bibtex)

For a Live Version of the crawler results, check out our [Periodic Measurements of the IPFS Network](https://trudi.weizenbaum-institut.de/ipfs_analysis.html)

## Building

You can build this in a containerized environment.
This will build on Debian Bullseye and extract the compiled binary to `out/`:
```bash
./build-in-docker.sh
```

This is the preferred way of compilation.
You can also manually compile the crawler.
This will need an older version of Go installed, since the most recent version is usually not supported by the QUIC implementation.

## Usage

To crawl the network once, execute the crawler with the corresponding config file:
```bash
export LIBP2P_ALLOW_WEAK_RSA_KEYS="" && export LIBP2P_SWARM_FD_LIMIT="10000" && ./out/libp2p-crawler --config dist/config_ipfs.yaml
```

One crawl will take 5-10 minutes, depending on your machine.

## Pin File to ipfs node.
```bash
./ipfspin.sh output_data_crawls/ipfs/visitedPeers_2025-06-25_03-00-20_UTC.json  10 IPFSCID 
```
### Docker

The image executes `dist/docker_entrypoint.sh` by default, which will set the environment variables and launch the crawler with all arguments provided to it.
This loads a config file located at `/libp2p-crawler/config.yaml` in the image.
You can thus override the executed config by mounting a different file to this location.

You'll need to mount the precomputed hashes as well as an output directory.
The working directory of the container is `/libp2p-crawler`.
A typical invocation could look like this:

```bash
docker run -it --rm \
  -v ./dist/config_ipfs.yaml:/libp2p-crawler/config.yaml \
  -v ./precomputed_hashes:/libp2p-crawler/precomputed_hashes \
  -v ./output_data_crawls:/libp2p-crawler/output_data_crawls \
  trudi-group/ipfs-crawler:latest
```

The crawler runs as `root` within the container and, thus, also writes files as `uid` `0`.
This is somewhat annoying on the host, since files in the mapped output directory will also be owned by `root`.

### Computing Preimages

**Important note:** We ship the pre-images necessary for a successful crawl, but you can compute them yourself with `make preimages`.
Note that the preimages only have to be computed *once*, it'll take some minutes, to compute them, though.

```bash
go build cmd/hash-precomputation/main.go
mv main cmd/hash-precomputation/hash-precomputation
./cmd/hash-precomputation/hash-precomputation
mkdir -p precomputed_hashes
mv preimages.csv precomputed_hashes/preimages.csv
```

## Configuration

The crawler is configured via a YAML configuration file.
Example configurations with sane defaults are provided in [dist/](dist):
- [dist/config_ipfs.yaml](dist/config_ipfs.yaml) contains a configuration to crawl the IPFS network.
- [dist/config_filecoin_mainnet.yaml](dist/config_filecoin_mainnet.yaml) contains a configuration to crawl the Filecoin mainnet.

### Bootstrap Peers

The crawler needs to know which peers to use to start a crawl.
These are configured via the configuration file.
To get the default bootstrap peers of an IPFS node, simply run ```./ipfs bootstrap list > bootstrappeers.txt```.

## In a Nutshell

This crawler is designed to enumerate all reachable nodes within the DHT/KAD-part of libp2p networks and return their neighborhood graph.
For each node it saves
* The ID
* All known multiaddresses that were found in the DHT
* If a connection could be established
* All peers in the routing table of the peer, if crawling succeeded
* The agent version, if the identify protocol succeeded
* Supported protocols, if the identify protocol succeeded
* Plugin-extensible metadata

This is achieved by sending multiple `FindNode`-requests to each node in the network, targeted in such a way that each request extracts the contents of exactly one DHT bucket.

The crawler is optimized for speed, to generate as accurate snapshots as possible.
It starts from the (configurable) bootstrap nodes, polls their buckets and continues to connect to every peer it has not seen so far.

For an in-depth dive and discussion to the crawler and the obtained results, you can watch @scriptkitty's talk at ProtocolLabs:

[![Link to YouTube](https://img.youtube.com/vi/jQI37Y25jwk/1.jpg)](https://www.youtube.com/watch?v=jQI37Y25jwk)

## Evaluation of Results

After running a few crawls, the output directory should have some data in it.
To run the evaluation and generate the same plots/tables as in the paper (and more!) you have the option to run it via Docker or manually.
We've compiled the details [in the README](./eval/README.md)

## Features

### Plugins

We support implementing plugins that interact with peers discovered through a crawl.
These plugins are executed, in order, for all peers that are connectable.
Output of all plugins is collected and appended to each node's metadata.

Currently implemented plugins:
- `bitswap-probe` probes nodes for content via Bitswap.
  This correctly handles different Bitswap versions and capabilities of the peers.
  See also [the README](./plugins/bsprobe/README.md).

### Node Caching

If configured, the crawler will cache the nodes it has seen.
The next crawl will then not only start at the boot nodes but also add all previously reachable nodes to the crawl queue.
This can increase the crawl speed, and therefore the accuracy of the snapshots, significantly.
Due to node churn, this setting is most reasonable when performing many consecutive crawls.

## Output of a crawl

A crawl writes two files to the output directory configured via the configuration file:
* ```visitedPeers_<start_of_crawl_datetime>.json```
* ```peerGraph_<start_of_crawl_datetime>.csv```

### Format of ```visitedPeers```

```visitedPeers``` contains a json structure with meta information about the crawl as well as each found node.
Each node entry corresponds to exactly one node on the network and has the following fields:
```json
{
  "id": "<multihash of the node id>",
  "multiaddrs": <list of multiaddresses>,
  "connection_error": null | "<human-readable error>",
  "result": null (if connection_error != null) | {
    "agent_version": "<agent version string, if known>",
    "supported_protocols": <list of supported protocols>,
    "crawl_begin_ts": "<timestamp of when crawling was initiated>",
    "crawl_end_ts": "<timestamp of when crawling was finished>",
    "crawl_error": null | "<human-readable error>",
    "plugin_results": null | {
      "<plugin name>": {
        "begin_timestamp": "<timestamp of when the plugin was executed on the peer>",
        "end_timestamp": "<timestamp of when the plugin finished executing on the peer>",
        "error": null | "<human-redable error>",
        "result": null (if error != null) | <return value of executing the plugin>
      }
    }
  }
}
```

The Node's ID is a [multihash](https://github.com/multiformats/multihash), the addresses a peer advertises are [multiaddresses](https://github.com/multiformats/multiaddr).
```crawlable``` is true/false and indicates, whether the respective node could be reached by the crawler or not. Note that the crawler will try to connect to *all* multiaddresses that it found in the DHT for a given peer.
```agent_version``` is simply the agent version string the peer provides when connecting to it.

Data example (somewhat anonymized):
```json
{
  "id": "12D3KooWDwu...",
  "multiaddrs": [
    "/ip6/::1/udp/4001/quic",
    "/ip4/127.0.0.1/udp/4001/quic",
    "/ip4/154.x.x.x/udp/4001/quic",
    "..."
  ],
  "connection_error": null,
  "result": {
    "agent_version": "kubo/0.18.1/675f8bd/docker",
    "supported_protocols": [
      "/libp2p/circuit/relay/0.2.0/hop",
      "/ipfs/ping/1.0.0",
      "...",
      "/ipfs/id/1.0.0",
      "/ipfs/id/push/1.0.0"
    ],
    "crawl_begin_ts": "2023-04-27T15:57:11.782371723+02:00",
    "crawl_end_ts": "2023-04-27T15:57:13.434195769+02:00",
    "crawl_error": null,
    "plugin_data": {
      "bitswap-probe": {
        "begin_timestamp": "2023-04-27T15:57:14.434195769+02:00",
        "end_timestamp": "2023-04-27T15:57:15.434195769+02:00",
        "error": null,
        "result": {
          "error": null,
          "haves": null,
          "dont_haves": [
            {
              "/": "QmY7Yh4UquoXHLPFo2XbhXkhBvFoPwmQUSa92pxnxjQuPU"
            }
          ],
          "blocks": null,
          "no_response": null
        }
      }
    }
  }
}
```

### Format of `peerGraph`

`peerGraph` is an edgelist, where each line in the file corresponds to one edge. A line has the form

```csv
source,target,target_crawlable,source_crawl_timestamp
```

Two nodes are connected, if the crawler found the peer `target` in the buckets of peer `source`.
Example line (somewhat anonymized):

```csv
12D3KooWD9QV2...,12D3KooWCDx5k1...,true,2023-04-14T03:18:06+01:00
```

which says that the peer with ID `12D3KooWD9QV2...` had an entry for peer `12D3KooWCDx5k1...` in its buckets and that the latter was reachable by our crawler.

If `target_crawlable` is `false`, this indicates that the crawler was not able to connect to or enumerate all of `target`'s peers.
Since some nodes reside behind NATs or are otherwise uncooperative, this is not uncommon to see.

## Libp2p complains about key lengths

Libp2p uses a minimum keylenght of [2048 bit](https://github.com/libp2p/go-libp2p-core/blob/master/crypto/rsa_common.go), whereas IPFS uses [512 bit](https://github.com/ipfs/infra/issues/378).
Therefore, the crawler can only connect to one IPFS bootstrap node and refuses a connection with the others, due to this key length mismatch.
Libp2p can be configured to ignore this mismatch via an environment variable:

```bash
export LIBP2P_ALLOW_WEAK_RSA_KEYS=""
```

## Socket limit

ipfs-crawler uses a lot of sockets.
On linux, this can result into "too many sockets" errors during connections.
Please raise the maximum number of sockets on linux via 
```bash
ulimit -n unlimited
```
or equivalent commands on different platforms.

## License

MIT, see [LICENSE](LICENSE).
