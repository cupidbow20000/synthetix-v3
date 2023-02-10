const path = require('path');
const dotenv = require('dotenv');

// Load common .env file at ./packages/config-common/.env
dotenv.config({ path: path.resolve(__dirname, '.env') });

require('@nomiclabs/hardhat-ethers');
require('hardhat-contract-sizer');
require('solidity-coverage');
require('@synthetixio/deployer');
require('@synthetixio/cli');

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: {
    version: '0.8.11',
    settings: {
      optimizer: {
        enabled: true,
        runs: 1,
      },
    },
  },
  networks: {
    local: {
      url: 'http://localhost:8545',
    },
    ['optimistic-kovan']: {
      url: process.env.NETWORK_ENDPOINT || 'https://kovan.optimism.io',
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : [],
    },
    ['optimistic-mainnet']: {
      url: process.env.NETWORK_ENDPOINT || 'https://mainnet.optimism.io',
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : [],
    },
    ['mainnet']: {
      url: process.env.NETWORK_ENDPOINT || 'http://127.0.0.1:8545/',
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : [],
    },
  },
  contractSizer: {
    strict: true,
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
  tenderly: {
    project: 'synthetix',
    username: 'synthetix-services',
  },
};
