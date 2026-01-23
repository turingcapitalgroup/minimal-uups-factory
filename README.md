# MinimalUUPSFactory

A minimal factory for deploying ERC-1967 UUPS proxies with no admin backdoors.

## Features

- Deploys minimal ERC-1967 proxies using solady's OptimisedLibClone bytecode
- Supports deterministic (CREATE2) deployment
- Supports initialization during deployment
- **No factory admin** - factory is out of the picture after deployment
- **No upgrade functions in factory** - upgrades only via UUPS `upgradeToAndCall()` on the proxy

## Installation

```bash
forge install
```

## Usage

### Deploy a proxy

```solidity
MinimalUUPSFactory factory = new MinimalUUPSFactory();

// Simple deployment
address proxy = factory.deploy(implementation);

// Deployment with initialization
bytes memory initData = abi.encodeCall(Implementation.initialize, (owner));
address proxy = factory.deployAndCall(implementation, initData);

// Deterministic deployment
address proxy = factory.deployDeterministic(implementation, salt);

// Deterministic deployment with initialization
address proxy = factory.deployDeterministicAndCall(implementation, salt, initData);
```

### Predict deterministic address

```solidity
address predicted = factory.predictDeterministicAddress(implementation, salt);
```

## Testing

```bash
forge test
```

## Deployment

### Setup

1. Copy `.env.example` to `.env` and configure your values:

```bash
cp .env.example .env
```

2. Import your deployer key into Foundry's keystore:

```bash
cast wallet import keyDeployer --interactive
```

3. Set `DEPLOYER_ADDRESS` in `.env` to match the imported keystore account.

### Available targets

| Target | Description |
|--------|-------------|
| `make deploy` | Deploy and verify on the configured network |
| `make deploy-no-verify` | Deploy without Etherscan verification |
| `make deploy-dry` | Simulate deployment (no broadcast) |
| `make deploy-local` | Deploy to a local Anvil instance |

## License

MIT
