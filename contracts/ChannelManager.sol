pragma solidity ^0.4.24;
pragma experimental ABIEncoderV2;

import "./lib/ECTools.sol";
import "./lib/ERC20.sol";
import "./lib/SafeMath.sol";

contract ChannelManager {
    using SafeMath for uint256;

    string public constant NAME = "Channel Manager";
    string public constant VERSION = "0.0.1";

    address public hub;
    uint256 public challengePeriod;
    ERC20 public approvedToken;

    uint256 public totalChannelWei;
    uint256 public totalChannelToken;

    event DidHubContractWithdraw (
        uint256 weiAmount,
        uint256 tokenAmount
    );

    // Note: the payload of DidUpdateChannel contains the state that caused
    // the update, not the state post-update (ex, if the update contains a
    // deposit, the event's ``pendingDeposit`` field will be present and the
    // event's ``balance`` field will not have been updated to reflect that
    // balance).
    event DidUpdateChannel (
        address indexed user,
        uint256 senderIdx,
        uint256[2] weiBalances,
        uint256[2] tokenBalances,
        uint256[4] pendingWeiUpdates,
        uint256[4] pendingTokenUpdates,
        uint256[2] txCount,
        bytes32 threadRoot,
        uint256 threadCount,
        uint256 timeout
    );

    // Note: unlike the DidUpdateChannel event, the ``DidStartExitChannel``
    // event will contain the channel state after any state that has been
    // applied as part of startExitWithUpdate.
    event DidStartExitChannel (
        address indexed user,
        uint256 senderIdx,
        uint256[2] weiBalances,
        uint256[2] tokenBalances,
        uint256[2] txCount,
        uint256 threadCount,
        address exitInitiator
    );

    // Note: like DidStartExitChannel, the payload contains thechannel state after
    // any update has been applied.
    event DidEmptyChannelWithChallenge (
        address indexed user,
        uint256 senderIdx,
        uint256[2] weiBalances,
        uint256[2] tokenBalances,
        uint256[2] txCount,
        bytes32 threadRoot,
        uint256 threadCount
    );

    event DidEmptyChannel (
        address indexed user,
        uint256 senderIdx,
        uint256[2] weiBalances,
        uint256[2] tokenBalances,
        uint256[2] txCount,
        uint256 threadCount,
        address exitInitiator
    );

    event DidStartExitThread (
        address user,
        address indexed sender,
        address indexed receiver,
        uint256 senderIdx,
        uint256[2] weiBalances,
        uint256[2] tokenBalances,
        uint256 txCount
    );

    event DidEmptyThread (
        address user,
        address indexed sender,
        address indexed receiver,
        uint256 senderIdx,
        uint256[2] channelWeiBalances,
        uint256[2] channelTokenBalances,
        uint256[2] channelTxCount,
        bytes32 channelThreadRoot,
        uint256 channelThreadCount
    );

    event DidNukeThreads(
        address indexed user,
        address senderAddress,
        uint256 weiAmount,
        uint256 tokenAmount,
        uint256[2] channelWeiBalances,
        uint256[2] channelTokenBalances,
        uint256[2] channelTxCount,
        bytes32 channelThreadRoot,
        uint256 channelThreadCount
    );

    enum Status {
       Open,
       ChannelDispute,
       ThreadDispute
    }

    struct Channel {
        uint256[3] weiBalances; // [hub, user, total]
        uint256[3] tokenBalances; // [hub, user, total]
        uint256[2] txCount; // persisted onchain even when empty [global, onchain]
        bytes32 threadRoot;
        uint256 threadCount;
        address exitInitiator;
        uint256 channelClosingTime;
        uint256 threadClosingTime;
        Status status;
        mapping(address => mapping(address => Thread)) threads; // channels[user].threads[sender][receiver]
    }

    struct Thread {
        uint256[2] weiBalances; // [hub, user]
        uint256[2] tokenBalances; // [hub, user]
        uint256 txCount; // persisted onchain even when empty
        bool inDispute; // needed so we don't close threads twice
    }

    mapping(address => Channel) public channels;

    bool locked;

    modifier onlyHub() {
        require(msg.sender == hub);
        _;
    }

    modifier noReentrancy() {
        require(!locked, "Reentrant call.");
        locked = true;
        _;
        locked = false;
    }

    constructor(address _hub, uint256 _challengePeriod, address _tokenAddress) public {
        hub = _hub;
        challengePeriod = _challengePeriod;
        approvedToken = ERC20(_tokenAddress);
    }

    function hubContractWithdraw(uint256 weiAmount, uint256 tokenAmount) public noReentrancy onlyHub {
        require(
            getHubReserveWei() >= weiAmount,
            "hubContractWithdraw: Contract wei funds not sufficient to withdraw"
        );
        require(
            getHubReserveTokens() >= tokenAmount,
            "hubContractWithdraw: Contract token funds not sufficient to withdraw"
        );

        hub.transfer(weiAmount);
        require(
            approvedToken.transfer(hub, tokenAmount),
            "hubContractWithdraw: Token transfer failure"
        );

        emit DidHubContractWithdraw(weiAmount, tokenAmount);
    }

    function getHubReserveWei() public view returns (uint256) {
        return address(this).balance.sub(totalChannelWei);
    }

    function getHubReserveTokens() public view returns (uint256) {
        return approvedToken.balanceOf(address(this)).sub(totalChannelToken);
    }

    function hubAuthorizedUpdate(
        address user,
        address recipient,
        uint256[2] weiBalances, // [hub, user]
        uint256[2] tokenBalances, // [hub, user]
        uint256[4] pendingWeiUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
        uint256[4] pendingTokenUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
        uint256[2] txCount, // [global, onchain] persisted onchain even when empty
        bytes32 threadRoot,
        uint256 threadCount,
        uint256 timeout,
        string sigUser
    ) public noReentrancy onlyHub {
        Channel storage channel = channels[user];
        require(channel.status == Status.Open, "channel must be open");

        // Usage:
        // 1. exchange operations to protect user from exchange rate fluctuations
        require(timeout == 0 || now < timeout, "the timeout must be zero or not have passed");

        // prepare state hash to check user sig
        bytes32 state = keccak256(
            abi.encodePacked(
                address(this),
                user,
                recipient,
                weiBalances, // [hub, user]
                tokenBalances, // [hub, user]
                pendingWeiUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
                pendingTokenUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
                txCount, // persisted onchain even when empty
                threadRoot,
                threadCount,
                timeout
            )
        );

        // check user sig against state hash
        require(user == ECTools.recoverSigner(state, sigUser));

        require(txCount[0] > channel.txCount[0], "global txCount must be higher than the current global txCount");
        require(txCount[1] >= channel.txCount[1], "onchain txCount must be higher or equal to the current onchain txCount");

        // offchain wei/token balances do not exceed onchain total wei/token
        require(weiBalances[0].add(weiBalances[1]) <= channel.weiBalances[2], "wei must be conserved");
        require(tokenBalances[0].add(tokenBalances[1]) <= channel.tokenBalances[2], "tokens must be conserved");

        // hub has enough reserves for wei/token deposits
        require(pendingWeiUpdates[0].add(pendingWeiUpdates[2]) <= getHubReserveWei(), "insufficient reserve wei for deposits");
        require(pendingTokenUpdates[0].add(pendingTokenUpdates[2]) <= getHubReserveTokens(), "insufficient reserve tokens for deposits");

        // wei is conserved
        require(channel.weiBalances[2].add(pendingWeiUpdates[0]).add(pendingWeiUpdates[2]) >=
                weiBalances[0].add(weiBalances[1]).add(pendingWeiUpdates[1]).add(pendingWeiUpdates[3]), "insufficient wei");

        // token is conserved
        require(channel.tokenBalances[2].add(pendingTokenUpdates[0]).add(pendingTokenUpdates[2]) >=
                tokenBalances[0].add(tokenBalances[1]).add(pendingTokenUpdates[1]).add(pendingTokenUpdates[3]), "insufficient token");

        // update hub wei balance
        // If the deposit is greater than the withdrawal, add the net of deposit minus withdrawal to the balances.
        // Assumes the deposit has *not yet* been added to the balances.
        if (pendingWeiUpdates[0] > pendingWeiUpdates[1]) {
            channel.weiBalances[0] = weiBalances[0].add(pendingWeiUpdates[0].sub(pendingWeiUpdates[1]));
        // Otherwise, if the deposit is less than or equal to the withdrawal,
        // Assumes the deposit has *already* been added to the balances.
        } else {
            channel.weiBalances[0] = weiBalances[0];
        }

        // update user wei balance
        // If the deposit is greater than the withdrawal, add the net of deposit minus withdrawal to the balances.
        // Assumes the deposit has *not yet* been added to the balances.
        if (pendingWeiUpdates[2] > pendingWeiUpdates[3]) {
            channel.weiBalances[1] = weiBalances[1].add(pendingWeiUpdates[2].sub(pendingWeiUpdates[3]));

        // Otherwise, if the deposit is less than or equal to the withdrawal,
        // Assumes the deposit has *already* been added to the balances.
        } else {
            channel.weiBalances[1] = weiBalances[1];
        }

        totalChannelWei = totalChannelWei.add(pendingWeiUpdates[0]).add(pendingWeiUpdates[2]).sub(pendingWeiUpdates[1]).sub(pendingWeiUpdates[3]);
        recipient.transfer(pendingWeiUpdates[3]);

        // update hub token balance
        // If the deposit is greater than the withdrawal, add the net of deposit minus withdrawal to the balances.
        // Assumes the deposit has *not yet* been added to the balances.
        if (pendingTokenUpdates[0] > pendingTokenUpdates[1]) {
            channel.tokenBalances[0] = tokenBalances[0].add(pendingTokenUpdates[0].sub(pendingTokenUpdates[1]));
        // Otherwise, if the deposit is less than or equal to the withdrawal,
        // Assumes the deposit has *already* been added to the balances.
        } else {
            channel.tokenBalances[0] = tokenBalances[0];
        }

        // update user token balance
        // If the deposit is greater than the withdrawal, add the net of deposit minus withdrawal to the balances.
        // Assumes the deposit has *not yet* been added to the balances.
        if (pendingTokenUpdates[2] > pendingTokenUpdates[3]) {
            channel.tokenBalances[1] = tokenBalances[1].add(pendingTokenUpdates[2].sub(pendingTokenUpdates[3]));

        // Otherwise, if the deposit is less than or equal to the withdrawal,
        // Assumes the deposit has *already* been added to the balances.
        } else {
            channel.tokenBalances[1] = tokenBalances[1];
        }

        totalChannelToken = totalChannelToken.add(pendingTokenUpdates[0]).add(pendingTokenUpdates[2]).sub(pendingTokenUpdates[1]).sub(pendingTokenUpdates[3]);
        require(approvedToken.transfer(recipient, pendingTokenUpdates[3]), "user token withdrawal transfer failed");

        // update channel total balances
        channel.weiBalances[2] = channel.weiBalances[2].add(pendingWeiUpdates[0]).add(pendingWeiUpdates[1]).sub(pendingWeiUpdates[2]).sub(pendingWeiUpdates[3]);
        channel.tokenBalances[2] = channel.tokenBalances[2].add(pendingTokenUpdates[0]).add(pendingTokenUpdates[1]).sub(pendingTokenUpdates[2]).sub(pendingTokenUpdates[3]);

        // update state variables
        channel.txCount = txCount;
        channel.threadRoot = threadRoot;
        channel.threadCount = threadCount;

        emit DidUpdateChannel(
            user,
            0, // senderIdx
            weiBalances,
            tokenBalances,
            pendingWeiUpdates,
            pendingTokenUpdates,
            txCount,
            threadRoot,
            threadCount,
            timeout
        );
    }

    function userAuthorizedUpdate(
        address recipient,
        uint256[2] weiBalances, // [hub, user]
        uint256[2] tokenBalances, // [hub, user]
        uint256[4] pendingWeiUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
        uint256[4] pendingTokenUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
        uint256[2] txCount, // persisted onchain even when empty
        bytes32 threadRoot,
        uint256 threadCount,
        uint256 timeout,
        string sigHub
    ) public payable noReentrancy {
        require(msg.value == pendingWeiUpdates[2], "msg.value is not equal to pending user deposit");

        Channel storage channel = channels[msg.sender];
        require(channel.status == Status.Open, "channel must be open");

        // Usage:
        // 1. exchange operations to protect hub from exchange rate fluctuations
        // 2. protect hub against user failing to send the transaction in a timely manner
        require(timeout == 0 || now < timeout, "the timeout must be zero or not have passed");

        // prepare state hash to check hub sig
        bytes32 state = keccak256(
            abi.encodePacked(
                address(this),
                msg.sender,
                recipient,
                weiBalances, // [hub, user]
                tokenBalances, // [hub, user]
                pendingWeiUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
                pendingTokenUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
                txCount, // persisted onchain even when empty
                threadRoot,
                threadCount,
                timeout
            )
        );

        // check hub sig against state hash
        require(hub == ECTools.recoverSigner(state, sigHub));

        require(txCount[0] > channel.txCount[0], "global txCount must be higher than the current global txCount");
        require(txCount[1] >= channel.txCount[1], "onchain txCount must be higher or equal to the current onchain txCount");

        // offchain wei/token balances do not exceed onchain total wei/token
        require(weiBalances[0].add(weiBalances[1]) <= channel.weiBalances[2], "wei must be conserved");
        require(tokenBalances[0].add(tokenBalances[1]) <= channel.tokenBalances[2], "tokens must be conserved");

        // hub has enough reserves for wei/token deposits
        require(pendingWeiUpdates[0] <= getHubReserveWei(), "insufficient reserve wei for deposits");
        require(pendingTokenUpdates[0] <= getHubReserveTokens(), "insufficient reserve tokens for deposits");

        // transfer user token deposit to this contract
        require(approvedToken.transferFrom(msg.sender, address(this), pendingTokenUpdates[2]), "user token deposit failed");

        // check that channel balances and pending deposits cover wei/token withdrawals
        require(channel.weiBalances[0].add(pendingWeiUpdates[0]) >= weiBalances[0].add(pendingWeiUpdates[1]), "insufficient wei for hub withdrawal");
        require(channel.weiBalances[1].add(pendingWeiUpdates[2]) >= weiBalances[1].add(pendingWeiUpdates[3]), "insufficient wei for user withdrawal");
        require(channel.tokenBalances[0].add(pendingTokenUpdates[0]) >= tokenBalances[0].add(pendingTokenUpdates[1]), "insufficient tokens for hub withdrawal");
        require(channel.tokenBalances[1].add(pendingTokenUpdates[2]) >= tokenBalances[1].add(pendingTokenUpdates[3]), "insufficient tokens for user withdrawal");

        // update hub wei channel balance, account for deposit/withdrawal in reserves
        channel.weiBalances[0] = weiBalances[0].add(pendingWeiUpdates[0]).sub(pendingWeiUpdates[1]);
        totalChannelWei = totalChannelWei.add(pendingWeiUpdates[0]).sub(pendingWeiUpdates[1]);

        // update user wei channel balance, account for deposit/withdrawal in reserves
        channel.weiBalances[1] = weiBalances[1].add(pendingWeiUpdates[2]).sub(pendingWeiUpdates[3]);
        totalChannelWei = totalChannelWei.add(pendingWeiUpdates[2]);
        recipient.transfer(pendingWeiUpdates[3]);

        // update hub token channel balance, account for deposit/withdrawal in reserves
        channel.tokenBalances[0] = tokenBalances[0].add(pendingTokenUpdates[0]).sub(pendingTokenUpdates[1]);
        totalChannelToken = totalChannelToken.add(pendingTokenUpdates[0]).sub(pendingTokenUpdates[1]);

        // update user token channel balance, account for deposit/withdrawal in reserves
        channel.tokenBalances[1] = tokenBalances[1].add(pendingTokenUpdates[2]).sub(pendingTokenUpdates[3]);
        totalChannelToken = totalChannelToken.add(pendingTokenUpdates[2]);
        require(approvedToken.transfer(recipient, pendingTokenUpdates[3]), "user token withdrawal transfer failed");

        // update channel total balances
        channel.weiBalances[2] = channel.weiBalances[2].add(pendingWeiUpdates[0]).add(pendingWeiUpdates[2]).sub(pendingWeiUpdates[1]).sub(pendingWeiUpdates[3]);
        channel.tokenBalances[2] = channel.tokenBalances[2].add(pendingTokenUpdates[0]).add(pendingTokenUpdates[2]).sub(pendingTokenUpdates[1]).sub(pendingTokenUpdates[3]);

        // update state variables
        channel.txCount = txCount;
        channel.threadRoot = threadRoot;
        channel.threadCount = threadCount;

        emit DidUpdateChannel(
            msg.sender,
            1, // senderIdx
            weiBalances,
            tokenBalances,
            pendingWeiUpdates,
            pendingTokenUpdates,
            txCount,
            threadRoot,
            threadCount,
            timeout
        );
    }

    /**********************
     * Unilateral Functions
     *********************/

    // start exit with onchain state
    function startExit(
        address user
    ) public noReentrancy {
        Channel storage channel = channels[user];
        require(channel.status == Status.Open, "channel must be open");

        require(msg.sender == hub || msg.sender == user, "exit initiator must be user or hub");

        channel.exitInitiator = msg.sender;
        channel.channelClosingTime = now.add(challengePeriod);
        channel.status = Status.ChannelDispute;

        emit DidStartExitChannel(
            user,
            msg.sender == hub ? 0 : 1,
            [channel.weiBalances[0], channel.weiBalances[1]],
            [channel.tokenBalances[0], channel.tokenBalances[1]],
            channel.txCount,
            channel.threadCount,
            channel.exitInitiator
        );
    }

    // start exit with offchain state
    function startExitWithUpdate(
        address user,
        uint256[2] weiBalances, // [hub, user]
        uint256[2] tokenBalances, // [hub, user]
        uint256[4] pendingWeiUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
        uint256[4] pendingTokenUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
        uint256[2] txCount, // [global, onchain] persisted onchain even when empty
        bytes32 threadRoot,
        uint256 threadCount,
        uint256 timeout,
        string sigHub,
        string sigUser
    ) public noReentrancy {
        Channel storage channel = channels[user];
        require(channel.status == Status.Open, "channel must be open");

        require(msg.sender == hub || msg.sender == user, "exit initiator must be user or hub");

        require(timeout == 0, "can't start exit with time-sensitive states");

        // prepare state hash to check hub sig
        bytes32 state = keccak256(
            abi.encodePacked(
                address(this),
                user,
                weiBalances, // [hub, user]
                tokenBalances, // [hub, user]
                pendingWeiUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
                pendingTokenUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
                txCount, // persisted onchain even when empty
                threadRoot,
                threadCount,
                timeout
            )
        );

        // check hub and user sigs against state hash
        require(hub == ECTools.recoverSigner(state, sigHub));
        require(user == ECTools.recoverSigner(state, sigUser));

        require(txCount[0] > channel.txCount[0], "global txCount must be higher than the current global txCount");
        require(txCount[1] >= channel.txCount[1], "onchain txCount must be higher or equal to the current onchain txCount");

        // offchain wei/token balances do not exceed onchain total wei/token
        require(weiBalances[0].add(weiBalances[1]) <= channel.weiBalances[2], "wei must be conserved");
        require(tokenBalances[0].add(tokenBalances[1]) <= channel.tokenBalances[2], "tokens must be conserved");

        // TODO UPDATE WITH pre-compiling deposits + withdrawals
        // pending onchain txs have been executed - force update offchain state to reflect this
        if (txCount[1] == channel.txCount[1]) {
            weiBalances[0] = weiBalances[0].add(pendingWeiUpdates[0]);
            weiBalances[1] = weiBalances[1].add(pendingWeiUpdates[2]);
            tokenBalances[0] = tokenBalances[0].add(pendingTokenUpdates[0]);
            tokenBalances[1] = tokenBalances[1].add(pendingTokenUpdates[2]);

        // pending onchain txs have *not* been executed - revert pending withdrawals back into offchain balances
        } else { //txCount[1] > channel.txCount[1]
            weiBalances[0] = weiBalances[0].add(pendingWeiUpdates[1]);
            weiBalances[1] = weiBalances[1].add(pendingWeiUpdates[3]);
            tokenBalances[0] = tokenBalances[0].add(pendingTokenUpdates[1]);
            tokenBalances[1] = tokenBalances[1].add(pendingTokenUpdates[3]);
        }

        // set the channel wei/token balances
        channel.weiBalances[0] = weiBalances[0];
        channel.weiBalances[1] = weiBalances[1];
        channel.tokenBalances[0] = tokenBalances[0];
        channel.tokenBalances[1] = tokenBalances[1];

        // update state variables
        channel.txCount = txCount;
        channel.threadRoot = threadRoot;
        channel.threadCount = threadCount;

        channel.exitInitiator = msg.sender;
        channel.channelClosingTime = now.add(challengePeriod);
        channel.status == Status.ChannelDispute;

        emit DidStartExitChannel(
            user,
            msg.sender == hub ? 0 : 1,
            [channel.weiBalances[0], channel.weiBalances[1]],
            [channel.tokenBalances[0], channel.tokenBalances[1]],
            channel.txCount,
            channel.threadCount,
            channel.exitInitiator
        );
    }

    // party that didn't start exit can challenge and empty
    function emptyChannelWithChallenge(
        address user,
        uint256[2] weiBalances, // [hub, user]
        uint256[2] tokenBalances, // [hub, user]
        uint256[4] pendingWeiUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
        uint256[4] pendingTokenUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
        uint256[2] txCount, // persisted onchain even when empty
        bytes32 threadRoot,
        uint256 threadCount,
        uint256 timeout,
        string sigHub,
        string sigUser
    ) public noReentrancy {
        Channel storage channel = channels[user];
        require(channel.status == Status.ChannelDispute, "channel must be in dispute");
        require(now < channel.channelClosingTime, "channel closing time must not have passed");

        require(msg.sender != channel.exitInitiator, "challenger can not be exit initiator");
        require(msg.sender == hub || msg.sender == user, "challenger must be either user or hub");

        require(timeout == 0, "can't start exit with time-sensitive states");

        // prepare state hash to check hub sig
        bytes32 state = keccak256(
            abi.encodePacked(
                address(this),
                user,
                weiBalances, // [hub, user]
                tokenBalances, // [hub, user]
                pendingWeiUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
                pendingTokenUpdates, // [hubDeposit, hubWithdrawal, userDeposit, userWithdrawal]
                txCount, // persisted onchain even when empty
                threadRoot,
                threadCount,
                timeout
            )
        );

        // check hub and user sigs against state hash
        require(hub == ECTools.recoverSigner(state, sigHub));
        require(user == ECTools.recoverSigner(state, sigUser));

        require(txCount[0] > channel.txCount[0], "global txCount must be higher than the current global txCount");
        require(txCount[1] >= channel.txCount[1], "onchain txCount must be higher or equal to the current onchain txCount");

        // offchain wei/token balances do not exceed onchain total wei/token
        require(weiBalances[0].add(weiBalances[1]) <= channel.weiBalances[2], "wei must be conserved");
        require(tokenBalances[0].add(tokenBalances[1]) <= channel.tokenBalances[2], "tokens must be conserved");

        // TODO UPDATE WITH pre-compiling deposits + withdrawals
        // pending onchain txs have been executed - force update offchain state to reflect this
        if (txCount[1] == channel.txCount[1]) {
            weiBalances[0] = weiBalances[0].add(pendingWeiUpdates[0]);
            weiBalances[1] = weiBalances[1].add(pendingWeiUpdates[2]);
            tokenBalances[0] = tokenBalances[0].add(pendingTokenUpdates[0]);
            tokenBalances[1] = tokenBalances[1].add(pendingTokenUpdates[2]);

        // pending onchain txs have *not* been executed - revert pending withdrawals back into offchain balances
        } else { //txCount[1] > channel.txCount[1]
            weiBalances[0] = weiBalances[0].add(pendingWeiUpdates[1]);
            weiBalances[1] = weiBalances[1].add(pendingWeiUpdates[3]);
            tokenBalances[0] = tokenBalances[0].add(pendingTokenUpdates[1]);
            tokenBalances[1] = tokenBalances[1].add(pendingTokenUpdates[3]);
        }

        // deduct hub/user wei/tokens from total channel balances
        channel.weiBalances[2] = channel.weiBalances[2].sub(weiBalances[0]).sub(weiBalances[1]);
        channel.tokenBalances[2] = channel.tokenBalances[2].sub(tokenBalances[0]).sub(tokenBalances[1]);

        // transfer hub wei balance from channel to reserves
        totalChannelWei = totalChannelWei.sub(channel.weiBalances[0]);
        channel.weiBalances[0] = 0;

        // transfer user wei balance to user
        totalChannelWei = totalChannelWei.sub(channel.weiBalances[1]);
        user.transfer(channel.weiBalances[1]);
        channel.weiBalances[1] = 0;

        // transfer hub token balance from channel to reserves
        totalChannelToken = totalChannelToken.sub(channel.tokenBalances[0]);
        channel.tokenBalances[0] = 0;

        // transfer user token balance to user
        totalChannelToken = totalChannelToken.sub(channel.tokenBalances[1]);
        require(approvedToken.transfer(user, channel.tokenBalances[1]), "user token withdrawal transfer failed");
        channel.tokenBalances[1] = 0;

        // update state variables
        channel.txCount = txCount;
        channel.threadRoot = threadRoot;
        channel.threadCount = threadCount;

        if (channel.threadCount > 0) {
            channel.threadClosingTime = now.add(challengePeriod);
            channel.status == Status.ThreadDispute;
        } else {
            channel.threadClosingTime = 0;
            channel.status == Status.Open;
        }

        channel.exitInitiator = address(0x0);
        channel.channelClosingTime = 0;


        emit DidEmptyChannelWithChallenge(
            user,
            msg.sender == hub ? 0 : 1,
            [channel.weiBalances[0], channel.weiBalances[1]],
            [channel.tokenBalances[0], channel.tokenBalances[1]],
            channel.txCount,
            channel.threadRoot,
            channel.threadCount
        );
    }

    // after timer expires - anyone can call
    function emptyChannel(
        address user
    ) public noReentrancy {
        Channel storage channel = channels[user];
        require(channel.status == Status.ChannelDispute, "channel must be in dispute");

        require(channel.channelClosingTime < now, "channel closing time must have passed");

        // deduct hub/user wei/tokens from total channel balances
        channel.weiBalances[2] = channel.weiBalances[2].sub(channel.weiBalances[0]).sub(channel.weiBalances[1]);
        channel.tokenBalances[2] = channel.tokenBalances[2].sub(channel.tokenBalances[0]).sub(channel.tokenBalances[1]);

        // transfer hub wei balance from channel to reserves
        totalChannelWei = totalChannelWei.sub(channel.weiBalances[0]);
        channel.weiBalances[0] = 0;

        // transfer user wei balance to user
        totalChannelWei = totalChannelWei.sub(channel.weiBalances[1]);
        user.transfer(channel.weiBalances[1]);
        channel.weiBalances[1] = 0;

        // transfer hub token balance from channel to reserves
        totalChannelToken = totalChannelToken.sub(channel.tokenBalances[0]);
        channel.tokenBalances[0] = 0;

        // transfer user token balance to user
        totalChannelToken = totalChannelToken.sub(channel.tokenBalances[1]);
        require(approvedToken.transfer(user, channel.tokenBalances[1]), "user token withdrawal transfer failed");
        channel.tokenBalances[1] = 0;

        if (channel.threadCount > 0) {
            channel.threadClosingTime = now.add(challengePeriod);
            channel.status == Status.ThreadDispute;
        } else {
            channel.threadClosingTime = 0;
            channel.status == Status.Open;
        }

        channel.exitInitiator = address(0x0);
        channel.channelClosingTime = 0;

        emit DidEmptyChannel(
            user,
            msg.sender == hub ? 0 : 1,
            [channel.weiBalances[0], channel.weiBalances[1]],
            [channel.tokenBalances[0], channel.tokenBalances[1]],
            channel.txCount,
            channel.threadCount,
            channel.exitInitiator
        );
    }

    // either party starts exit with initial state
    function startExitThread(
        address user,
        address sender,
        address receiver,
        uint256[2] weiBalances, // [sender, receiver]
        uint256[2] tokenBalances, // [sender, receiver]
        uint256 txCount,
        bytes proof,
        string sig
    ) public noReentrancy {
        Channel storage channel = channels[user];
        require(channel.status == Status.ThreadDispute, "channel must be in thread dispute phase");
        require(now < channel.threadClosingTime, "channel thread closing time must not have passed");
        require(msg.sender == hub || msg.sender == user, "thread exit initiator must be user or hub");

        Thread storage thread = channel.threads[sender][receiver];
        require(!thread.inDispute, "thread must not already be in dispute");
        require(txCount > thread.txCount, "thread txCount must be higher than the current thread txCount");

        // TODO Use _verifyThread everywhere possible

        // prepare state hash to check sender sig
        bytes32 state = keccak256(
            abi.encodePacked(
                address(this),
                user,
                sender,
                receiver,
                weiBalances, // [hub, user]
                tokenBalances, // [hub, user]
                txCount // persisted onchain even when empty
            )
        );

        // check sender sig matches state hash
        require(sender == ECTools.recoverSigner(state, sig));

        // Check the initial thread state is in the threadRoot
        require(_isContained(state, proof, channel.threadRoot) == true, "initial thread state is not contained in threadRoot");

        thread.weiBalances = weiBalances;
        thread.tokenBalances = tokenBalances;
        thread.txCount = txCount;
        thread.inDispute = true;

        emit DidStartExitThread(
            user,
            sender,
            receiver,
            msg.sender == hub ? 0 : 1,
            thread.weiBalances,
            thread.tokenBalances,
            thread.txCount
        );
    }

    // either party starts exit with offchain state
    function startExitThreadWithUpdate(
        address user,
        address[2] threadMembers, //[sender, receiver]
        uint256[2] weiBalances, // [sender, receiver]
        uint256[2] tokenBalances, // [sender, receiver]
        uint256 txCount,
        bytes proof,
        string sig,
        uint256[2] updatedWeiBalances, // [sender, receiver]
        uint256[2] updatedTokenBalances, // [sender, receiver]
        uint256 updatedTxCount,
        string updateSig
    ) public noReentrancy {
        Channel storage channel = channels[user];
        require(channel.status == Status.ThreadDispute, "channel must be in thread dispute phase");
        require(now < channel.threadClosingTime, "channel thread closing time must not have passed");
        require(msg.sender == hub || msg.sender == user, "thread exit initiator must be user or hub");

        Thread storage thread = channel.threads[threadMembers[0]][threadMembers[1]];
        require(!thread.inDispute, "thread must not already be in dispute");
        require(txCount > thread.txCount, "thread txCount must be higher than the current thread txCount");

        _verifyThread(msg.sender, sig, user, threadMembers, weiBalances, tokenBalances, txCount, proof, channel.threadRoot);

        // *********************
        // PROCESS THREAD UPDATE
        // *********************

        require(updatedTxCount > txCount, "updated thread txCount must be higher than the initial thread txCount");
        require(updatedWeiBalances[0].add(updatedWeiBalances[1]) == weiBalances[0].add(weiBalances[1]), "updated wei balances must match sum of initial wei balances");
        require(updatedTokenBalances[0].add(updatedTokenBalances[1]) == tokenBalances[0].add(tokenBalances[1]), "updated token balances must match sum of initial token balances");

        require(updatedWeiBalances[1] > weiBalances[1], "receiver wei balance must always increase");
        require(updatedTokenBalances[1] > tokenBalances[1], "receiver token balance must always increase");

        // Note: explicitly set threadRoot == 0x0 because then it doesn't get checked by _isContained (updated state is not part of root)
        _verifyThread(msg.sender, updateSig, user, threadMembers, updatedWeiBalances, updatedTokenBalances, updatedTxCount, proof, bytes32(0x0));

        thread.weiBalances = updatedWeiBalances;
        thread.tokenBalances = updatedTokenBalances;
        thread.txCount = updatedTxCount;
        thread.inDispute = true;

        emit DidStartExitThread(
            user,
            threadMembers[0],
            threadMembers[1],
            msg.sender == hub ? 0 : 1,
            thread.weiBalances,
            thread.tokenBalances,
            thread.txCount
        );
    }

    // non-sender can empty anytime with a state update after startExitThread/WithUpdate is called
    function fastEmptyThread(
        address user,
        address sender,
        address receiver,
        uint256[2] weiBalances,
        uint256[2] tokenBalances,
        uint256 txCount,
        // bytes proof,
        string sig
    ) public noReentrancy {
        Channel storage channel = channels[user];
        require(channel.status == Status.ThreadDispute, "channel must be in thread dispute phase");
        require(now < channel.threadClosingTime, "channel thread closing time must not have passed");
        require((msg.sender == hub && sender == user) || (msg.sender == user && receiver == user), "only hub or user, as the non-sender, can call this function");

        Thread storage thread = channel.threads[sender][receiver];
        require(thread.inDispute, "thread must be in dispute");

        // assumes that the non-sender has a later thread state than what was being proposed when the thread exit started
        require(txCount > thread.txCount, "thread txCount must be higher than the current thread txCount");
        require(weiBalances[0].add(weiBalances[1]) == thread.weiBalances[0].add(thread.weiBalances[1]), "updated wei balances must match sum of thread wei balances");
        require(tokenBalances[0].add(tokenBalances[1]) == thread.tokenBalances[0].add(thread.tokenBalances[1]), "updated token balances must match sum of thread token balances");

        // prepare state hash to check sender sig
        bytes32 state = keccak256(
            abi.encodePacked(
                address(this),
                user,
                sender,
                receiver,
                weiBalances, // [hub, user]
                tokenBalances, // [hub, user]
                txCount // persisted onchain even when empty
            )
        );

        // check sender sig matches state hash
        require(sender == ECTools.recoverSigner(state, sig));

        // deduct hub/user wei/tokens about to be emptied from the thread from the total channel balances
        channel.weiBalances[2] = channel.weiBalances[2].sub(weiBalances[0]).sub(weiBalances[1]);
        channel.tokenBalances[2] = channel.tokenBalances[2].sub(tokenBalances[0]).sub(tokenBalances[1]);

        // transfer hub thread wei balance from channel to reserves
        totalChannelWei = totalChannelWei.sub(weiBalances[0]);
        thread.weiBalances[0] = 0;

        // transfer user thread wei balance to user
        totalChannelWei = totalChannelWei.sub(weiBalances[1]);
        user.transfer(weiBalances[1]);
        thread.weiBalances[1] = 0;

        // transfer hub thread token balance from channel to reserves
        totalChannelToken = totalChannelToken.sub(tokenBalances[0]);
        thread.tokenBalances[0] = 0;

        // transfer user thread token balance to user
        totalChannelToken = totalChannelToken.sub(tokenBalances[1]);
        require(approvedToken.transfer(user, tokenBalances[1]), "user token withdrawal transfer failed");
        thread.tokenBalances[1] = 0;

        thread.txCount = txCount;
        thread.inDispute = false;

        // decrement the channel threadCount
        channel.threadCount = channel.threadCount.sub(1);

        // if this is the last thread being emptied, re-open the channel
        if (channel.threadCount == 0) {
            channel.threadRoot = bytes32(0x0);
            channel.threadClosingTime = 0;
            channel.status = Status.Open;
        }

        emit DidEmptyThread(
            user,
            sender,
            receiver,
            msg.sender == hub ? 0 : 1,
            [channel.weiBalances[0], channel.weiBalances[1]],
            [channel.tokenBalances[0], channel.tokenBalances[1]],
            channel.txCount,
            channel.threadRoot,
            channel.threadCount
        );
    }

    // after timer expires, anyone can empty with onchain state
    function emptyThread(
        address user,
        address sender,
        address receiver
    ) public noReentrancy {
        Channel storage channel = channels[user];
        require(channel.status == Status.ThreadDispute, "channel must be in thread dispute");
        require(channel.threadClosingTime < now, "thread closing time must have passed");

        Thread storage thread = channel.threads[sender][receiver];
        require(thread.inDispute, "thread must be in dispute");

        // deduct hub/user wei/tokens about to be emptied from the thread from the total channel balances
        channel.weiBalances[2] = channel.weiBalances[2].sub(thread.weiBalances[0]).sub(thread.weiBalances[1]);
        channel.tokenBalances[2] = channel.tokenBalances[2].sub(thread.tokenBalances[0]).sub(thread.tokenBalances[1]);

        // transfer hub thread wei balance from channel to reserves
        totalChannelWei = totalChannelWei.sub(thread.weiBalances[0]);
        thread.weiBalances[0] = 0;

        // transfer user thread wei balance to user
        totalChannelWei = totalChannelWei.sub(thread.weiBalances[1]);
        user.transfer(thread.weiBalances[1]);
        thread.weiBalances[1] = 0;

        // transfer hub thread token balance from channel to reserves
        totalChannelToken = totalChannelToken.sub(thread.tokenBalances[0]);
        thread.tokenBalances[0] = 0;

        // transfer user thread token balance to user
        totalChannelToken = totalChannelToken.sub(thread.tokenBalances[1]);
        require(approvedToken.transfer(user, thread.tokenBalances[1]), "user token withdrawal transfer failed");
        thread.tokenBalances[1] = 0;

        thread.inDispute = false;

        // decrement the channel threadCount
        channel.threadCount = channel.threadCount.sub(1);

        // if this is the last thread being emptied, re-open the channel
        if (channel.threadCount == 0) {
            channel.threadRoot = bytes32(0x0);
            channel.threadClosingTime = 0;
            channel.status = Status.Open;
        }

        emit DidEmptyThread(
            user,
            sender,
            receiver,
            msg.sender == hub ? 0 : 1,
            [channel.weiBalances[0], channel.weiBalances[1]],
            [channel.tokenBalances[0], channel.tokenBalances[1]],
            channel.txCount,
            channel.threadRoot,
            channel.threadCount
        );
    }

    // anyone can call to re-open an account stuck in threadDispute after 10x challengePeriods
    function nukeThreads(
        address user
    ) public noReentrancy {
        Channel storage channel = channels[user];
        require(channel.status == Status.ThreadDispute, "channel must be in thread dispute");
        require(channel.threadClosingTime.add(challengePeriod.mul(10)) < now, "thread closing time must have passed by 10 challenge periods");

        // transfer any remaining channel wei to user
        totalChannelWei = totalChannelWei.sub(channel.weiBalances[2]);
        user.transfer(channel.weiBalances[2]);
        uint256 weiAmount = channel.weiBalances[2];
        channel.weiBalances[2] = 0;

        // TODO document this attack vector
        // 1. I deposit 0.5 ETH -> channel
        // 2. I open 5 threads with 0.1 ETH each
        // 3. I dispute 2 of them, and let 3 expire (hub doesn't have)
        // 4. I call nukeThreads
        // 5. I deposit 0.5 ETH -> channel
        // 6. I open the 3 same expired threads again
        // 7. I replay attack the expired threads with my state that the hub doesn't know about

        // transfer any remaining channel tokens to user
        totalChannelToken = totalChannelToken.sub(channel.tokenBalances[2]);
        require(approvedToken.transfer(user, channel.tokenBalances[2]), "user token withdrawal transfer failed");
        uint256 tokenAmount = channel.tokenBalances[2];
        channel.tokenBalances[2] = 0;

        // reset channel params
        channel.threadCount = 0;
        channel.threadRoot = bytes32(0x0);
        channel.threadClosingTime = 0;
        channel.status = Status.Open;

        emit DidNukeThreads(
            user,
            msg.sender,
            weiAmount,
            tokenAmount,
            [channel.weiBalances[0], channel.weiBalances[1]],
            [channel.tokenBalances[0], channel.tokenBalances[1]],
            channel.txCount,
            channel.threadRoot,
            channel.threadCount
        );
    }

    function _verifyThread(
        address sender,
        string sig,
        address user,
        address[2] threadMembers,
        uint256[2] weiBalances,
        uint256[2] tokenBalances,
        uint256 txCount,
        bytes proof,
        bytes32 threadRoot
    ) internal view {
        bytes32 state = keccak256(
            abi.encodePacked(
                address(this),
                user,
                threadMembers,
                weiBalances, // [hub, user]
                tokenBalances, // [hub, user]
                txCount // persisted onchain even when empty
            )
        );
        require(sender == ECTools.recoverSigner(state, sig));

        if (threadRoot != bytes32(0x0)) {
            require(_isContained(state, proof, threadRoot) == true, "initial thread state is not contained in threadRoot");
        }
    }

    function _isContained(bytes32 _hash, bytes _proof, bytes32 _root) internal pure returns (bool) {
        bytes32 cursor = _hash;
        bytes32 proofElem;

        for (uint256 i = 64; i <= _proof.length; i += 32) {
            assembly { proofElem := mload(add(_proof, i)) }

            if (cursor < proofElem) {
                cursor = keccak256(abi.encodePacked(cursor, proofElem));
            } else {
                cursor = keccak256(abi.encodePacked(proofElem, cursor));
            }
        }

        return cursor == _root;
    }
}
