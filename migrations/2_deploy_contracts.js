const EC = artifacts.require("./ECTools.sol");
const LC = artifacts.require("./ChannelManager.sol");
const StandardToken = artifacts.require("./StandardToken.sol");
const config = require("../config.json")

module.exports = async function(deployer, network, accounts) {
  await deployer.deploy(EC);

  let tokenAddress = "0x0"; // change to BOOTY address for mainnet

  if (network !== "mainnet" && network !== "rinkeby") {
    const supply = web3.utils.toBN(web3.utils.toWei("696969", "ether"));
    await deployer.deploy(
      StandardToken,
      supply,
      config.token.name,
      config.token.decimals,
      config.token.ticker
    );
    const standardToken = await StandardToken.deployed();
    tokenAddress = standardToken.address;
  }

  await deployer.link(EC, LC);
  await deployer.deploy(
    LC,
    accounts[0],
    config.timeout,
    tokenAddress
  );
};
