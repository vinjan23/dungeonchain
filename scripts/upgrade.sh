#!/bin/bash

# the upgrade is a fork, "true" otherwise
FORK=${FORK:-"false"}

OLD_VERSION=v4.0.0
UPGRADE_WAIT=${UPGRADE_WAIT:-20}
HOME=mytestnet
ROOT=$(pwd)
DENOM=udgn
CHAIN_ID=localdungeon
SOFTWARE_UPGRADE_NAME="v5"
SLEEP_TIME=2
BINARY=dungeond
export KEY="acc0"
export KEY2="acc1"
echo "STARTING SCRIPT"

if [[ "$FORK" == "true" ]]; then
    export DUNGEON_HALT_HEIGHT=20
fi
# underscore so that go tool will not take gocache into account
mkdir -p _build/gocache
export GOMODCACHE=$ROOT/_build/gocache

# install old binary if not exist
#https://github.com/Crypto-Dungeon/dungeonchain/archive/refs/tags/v0.1.0.zip
# Checkin old binary
if [ ! -f "_build/$OLD_VERSION.zip" ] &> /dev/null
then
    mkdir -p _build/old
    wget -c "https://github.com/Crypto-Dungeon/dungeonchain/archive/refs/tags/${OLD_VERSION}.zip" -O _build/${OLD_VERSION}.zip
    unzip _build/${OLD_VERSION}.zip -d _build
fi

# reinstall old binary
if [ $# -eq 1 ] && [ $1 == "--reinstall-old" ] || ! command -v _build/old/$BINARY &> /dev/null; then
    cd ./_build/dungeonchain-${OLD_VERSION:1}
    GOBIN="$ROOT/_build/old" go install -mod=readonly ./...
    cd ../..
fi

# install new binary
echo "CHECKING NEW BINARY"
if ! command -v _build/new/$BINARY &> /dev/null
then
    echo "Installing new binary..."
    mkdir -p _build/new
    GOBIN="$ROOT/_build/new" go install -mod=readonly ./...
fi

if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "running old node"
    screen -L -dmS node1 bash scripts/run-node-test.sh _build/old/$BINARY $DENOM --Logfile $HOME/log-screen.txt
else
    screen -L -Logfile $HOME/log-screen.txt -dmS node1 bash scripts/run-node-test.sh _build/old/$BINARY $DENOM
fi

sleep 5 # wait for note to start


run_fork () {
    echo "forking"

    while true; do
        BLOCK_HEIGHT=$(./_build/old/$BINARY status | jq '.SyncInfo.latest_block_height' -r)
        # if BLOCK_HEIGHT is not empty
        if [ ! -z "$BLOCK_HEIGHT" ]; then
            echo "BLOCK_HEIGHT = $BLOCK_HEIGHT"
            sleep 10
        else
            echo "BLOCK_HEIGHT is empty, forking"
            break
        fi
    done
}

run_upgrade () {
    echo -e "\n\n=> =>start upgrading"

    # Get upgrade height, 12 block after (6s)
    STATUS_INFO=($(./_build/old/$BINARY status --home $HOME | jq -r '.sync_info.latest_block_height'))
    UPGRADE_HEIGHT=$((STATUS_INFO + 20))
    echo "UPGRADE_HEIGHT = $UPGRADE_HEIGHT"

    tar -cf ./_build/new/$BINARY.tar -C ./_build/new $BINARY
    SUM=$(shasum -a 256 ./_build/new/$BINARY.tar | cut -d ' ' -f1)


    cat > proposal.json << EOF
{
    "messages": [
        {
            "@type": "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade",
            "authority": "dungeon10d07y265gmmuvt4z0w9aw880jnsr700j53vrug",
            "plan": {
                "name": "$SOFTWARE_UPGRADE_NAME",
                "time": "0001-01-01T00:00:00Z",
                "height": "$UPGRADE_HEIGHT",
                "info": "test",
                "upgraded_client_state": null
            }
        }
    ],
    "metadata": "ipfs://CID",
    "deposit": "200000${DENOM}",
    "title": "Software Upgrade $SOFTWARE_UPGRADE_NAME",
    "summary": "Upgrade to version $SOFTWARE_UPGRADE_NAME"
}
EOF

    echo "submit upgrade"
    echo "Proposal content:"
    cat proposal.json

  ./_build/old/$BINARY tx gov submit-proposal proposal.json \
      --from=$KEY \
      --keyring-backend=test \
      --chain-id=$CHAIN_ID \
      --home=$HOME \
      -y
    sleep 3

    echo "Deposit"

    ./_build/old/$BINARY tx gov deposit 1 "10000000${DENOM}" --from $KEY --keyring-backend test --chain-id $CHAIN_ID --home $HOME -y > /dev/null

    sleep 2

    echo "Vote proposal validator1"

    ./_build/old/$BINARY tx gov vote 1 yes --from $KEY --keyring-backend test --chain-id $CHAIN_ID --home $HOME -y > /dev/null

    sleep 3

    echo "Vote proposal user2"

    ./_build/old/$BINARY tx gov vote 1 yes --from $KEY2 --keyring-backend test --chain-id $CHAIN_ID --home $HOME -y > /dev/null

    sleep 5

    # determine block_height to halt
    while true; do
        BLOCK_HEIGHT=$(./_build/old/$BINARY status | jq '.sync_info.latest_block_height' -r)
        if [ $BLOCK_HEIGHT = "$UPGRADE_HEIGHT" ]; then
            # assuming running only 1 dungeond
            echo "BLOCK HEIGHT = $UPGRADE_HEIGHT REACHED, KILLING OLD ONE"
            pkill dungeond
            break
        else
            ./_build/old/$BINARY q gov proposal 1 --output=json | jq ".status"
            echo "BLOCK_HEIGHT = $BLOCK_HEIGHT"
            sleep 1
        fi
    done
}

# if FORK = true
if [[ "$FORK" == "true" ]]; then
    run_fork
    unset UPGRADE_HEIGHT
else
    run_upgrade
fi

sleep 1

# run new node
echo -e "\n\n=> =>continue running nodes after upgrade"
./_build/new/dungeond start --home mytestnet