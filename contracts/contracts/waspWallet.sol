// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "./waspMaster.sol";

// - checkUpkeep
// - performUpkeep
// - mint
// - collect
// - burn
// - withdraw
// - deposit

contract WaspWallet is AutomationCompatibleInterface {
    IUniswapV3Factory public factory;
    INonfungiblePositionManager public nonfungiblePositionManager;
    struct positionData {
        uint256 tokenId;
        uint128 liquidity;
        int24 lowerTick;
        int24 upperTick;
        uint256 liqAmount0;
        uint256 liqAmount1;
        uint256 fees0;
        uint256 fees1;
    }

    positionData public _position;

    waspMaster.CLMOrder public _clmOrder;

    constructor(
        address _factory,
        address _positionManager,
        waspMaster.CLMOrder memory clmOrder
    ) {
        factory = IUniswapV3Factory(_factory);
        nonfungiblePositionManager = INonfungiblePositionManager(
            _positionManager
        );
        _clmOrder = clmOrder;
    }

    /*///////////////////////////////////////////////////////////////
                          Chainlink Automation
    //////////////////////////////////////////////////////////////*/

    function checkUpKeep()
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = checkConditions(
            _clmOrder.token0,
            _clmOrder.token1,
            _clmOrder.fee
        );
        performData = checkData;
    }

    function performUpkeep(bytes calldata performData) external override {
        burnPosition();
        collectAllFees();
        /// mint new position
    }

    /*///////////////////////////////////////////////////////////////
                           Extrass
    //////////////////////////////////////////////////////////////*/

    function checkConditions(
        address _tokenIn,
        address _tokenOut,
        uint24 fee
    ) internal view returns (bool) {
        (uint160 _newprice, int24 _newtick) = exchangeRouter.getPrice(
            _tokenIn,
            _tokenOut,
            fee
        );
        // (int24 _lowerTick,int24 _upperTick) = getRangeTicks(_tokenIn,_tokenOut, fee);

        // Calculates the greatest tick value such that getRatioAtTick(tick) <= ratio
        // The greatest tick for which the ratio is less than or equal to the input ratio
        require(_lowerTick < _upperTick);
        if (_lowerTick <= _newtick <= _upperTick) {
            return false;
        } else {
            return true;
        }
    }

    /*///////////////////////////////////////////////////////////////
                           Uniswap functions
    //////////////////////////////////////////////////////////////*/

    function getPrice(
        address tokenIn,
        address tokenOut,
        uint24 fee
    ) public view returns (uint160, int24) {
        IUniswapV3Pool pool = IUniswapV3Pool(
            factory.getPool(tokenIn, tokenOut, fee)
        );
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = pool.slot0();
        return (sqrtPriceX96, tick);
    }

    function getRangeTicks(
        address _tokenIn,
        address _tokenOut,
        uint24 fee
    ) public view returns (int24 lowerTick, int24 upperTick) {
        (uint160 _sqrtPriceX96, int24 tick) = getPrice(
            _tokenIn,
            _tokenOut,
            fee
        );
        lowerTick = tick - 500;
        upperTick = tick + 500;
        return (lowerTick, upperTick);
    }

    //The caller of this method receives a callback in the form of IUniswapV3MintCallback#uniswapV3MintCallback
    /// in which they must pay any token0 or token1 owed for the liquidity. The amount of token0/token1 due depends
    /// on tickLower, tickUpper, the amount of liquidity, and the current price.
    //******* But how does the user pay and what amount ? *******//
    function mintPosition(
        address _tokenIn,
        address _tokenOut,
        uint24 fee,
        address owner,
        uint256 _amount0,
        uint256 _amount1
    ) external payable returns (uint256 amount0, uint256 amount1) {
        // require(_amount != 0);
        (int24 _tickLower, int24 _tickUpper) = getRangeTicks(
            _tokenIn,
            _tokenOut,
            fee
        );

        // Approve the position manager
        TransferHelper.safeApprove(
            _tokenIn,
            address(nonfungiblePositionManager),
            _amount0
        );
        TransferHelper.safeApprove(
            _tokenOut,
            address(nonfungiblePositionManager),
            _amount1
        );

        INonfungiblePositionManager.MintParams
            memory params = INonfungiblePositionManager.MintParams({
                token0: _tokenIn,
                token1: _tokenOut,
                fee: fee,
                tickLower: _tickLower,
                tickUpper: _tickUpper,
                amount0Desired: _amount0,
                amount1Desired: _amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: owner,
                deadline: block.timestamp
            });

        (tokenId, , amount0, amount1) = nonfungiblePositionManager.mint(params);

        _position = positionData({
            tokenId: tokenId,
            liquidity: 0,
            lowerTick: _tickLower,
            upperTick: _tickUpper,
            liqAmount0: (_position.liqAmount0 + amount0),
            liqAmount1: (_position.liqAmount1 + amount1),
            fees0: 0,
            fees1: 0
        });
        return (amount0, amount1);
    }

    function decreaseLiquidityInHalf()
        external
        returns (uint256 amount0, uint256 amount1)
    {
        // caller must be the owner of the NFT
        // require(msg.sender == deposits[tokenId].owner, "Not the owner");
        // get liquidity data for tokenId

        // amount0Min and amount1Min are price slippage checks
        // if the amount received after burning is not greater than these minimums, transaction will fail
        INonfungiblePositionManager.DecreaseLiquidityParams
            memory params = INonfungiblePositionManager
                .DecreaseLiquidityParams({
                    tokenId: _position.tokenId,
                    liquidity: 0, // decreasing it to 0
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                });

        (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(
            params
        );

        //send liquidity back to owner
        _sendToOwner(tokenId, amount0, amount1);
    }

    //Can be used to trigger a recalculation of fees owed to a position by calling with an amount of 0
    function burnPosition() external payable {
        nonfungiblePositionManager.burn(tokenId);
    }

    function collectAllFees()
        external
        returns (uint256 amount0, uint256 amount1)
    {
        // Caller must own the ERC721 position, meaning it must be a deposit

        // set amount0Max and amount1Max to uint256.max to collect all fees
        // alternatively can set recipient to msg.sender and avoid another transaction in `sendToOwner`
        INonfungiblePositionManager.CollectParams
            memory params = INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });

        (amount0, amount1) = nonfungiblePositionManager.collect(params);

        // send collected feed back to owner
        _sendToOwner(tokenId, amount0, amount1);
    }
}

interface IUniswapV3Factory {
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address pool);
}

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(
        MintParams memory params
    )
        external
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    function collect(
        CollectParams memory params
    ) external returns (uint256 amount0, uint256 amount1);

    function burn(uint256 tokenId) external;
}