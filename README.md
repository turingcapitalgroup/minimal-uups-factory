# MinimalUUPSFactory

A minimal factory for deploying ERC-1967 UUPS proxies with no admin backdoors.

## Features

- Deploys minimal ERC-1967 proxies using solady's LibClone bytecode
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

## License

MIT
