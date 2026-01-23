# Makefile for MinimalUUPSFactory

-include .env

.PHONY: build test clean deploy

# Build
build:
	forge build

# Test
test:
	forge test

# Format
fmt:
	forge fmt

# Clean
clean:
	forge clean

# Deploy (requires RPC_URL and PRIVATE_KEY in .env)
deploy:
	forge script script/Deploy.s.sol:DeployScript --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast --verify

# Deploy without verification
deploy-no-verify:
	forge script script/Deploy.s.sol:DeployScript --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast

# Dry run deployment
deploy-dry:
	forge script script/Deploy.s.sol:DeployScript --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY)

# Local anvil deployment
deploy-local:
	forge script script/Deploy.s.sol:DeployScript --rpc-url http://localhost:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast
