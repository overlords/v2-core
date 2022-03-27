pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

// 配对合约
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath for uint256;
    using UQ112x112 for uint224;

    //最小流动性 1000
    uint256 public constant MINIMUM_LIQUIDITY = 10**3;

    // 取hash过后的前4位十六进制，共8个字符，表示调用方法的方法名
    // transfer(address,uint256) 表示接口方法中的方法名和参数类型
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory; //工厂合约地址
    address public token0; // tokenA
    address public token1; // tokenB

    //使用单个存储插槽，可通过getReserves访问
    uint112 private reserve0; // 储备量0
    uint112 private reserve1; // 储备量1
    uint32 private blockTimestampLast; // 时间戳

    uint256 public price0CumulativeLast; //价格0
    uint256 public price1CumulativeLast; //价格1 https://github.com/Uniswap/uniswap-v2-periphery/blob/master/contracts/examples/ExampleOracleSimple.sol

    //储备金0 * 储备金1，截至最近一次流动性事件后
    //在最近一次流动性事件之后的K值
    uint256 public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    //修饰符：防止重入的锁
    uint256 private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    //获取储备量
    function getReserves()
        public
        view
        returns (
            uint112 _reserve0,
            uint112 _reserve1,
            uint32 _blockTimestampLast
        )
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    //私有的安全发送函数
    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        //通过call方法进行合约调用
        //在合约中调用另一个合约，也可以通过接口合约调用
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        //校验方法调用的结果
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    //铸造事件
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    //销毁事件
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);

    //交换事件
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    //同步事件
    event Sync(uint112 reserve0, uint112 reserve1);

    // 初始化构造方法，给工厂合约部署者赋值
    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    // 初始化部署合约
    // 由工厂合约来完成
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    // 更新储备量
    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 _reserve0,
        uint112 _reserve1
    ) private {
        //防止溢出
        //校验余额0和余额1小于uin112最大值
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');

        // 对block.timestamp 模上2**32得到余额为32位的uin32数
        // block.timestamp 区块链时间戳
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);

        //计算已使用时间; 当前时间戳-最近一次流动性事件的时间戳
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

        //满足条件 (间隔时间 > 0 && 储备量0,1 != 0)
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            // 最后累计的价格0 = UQ112(储备量1 / 储备量0) * 时间流逝
            // 最后累计的价格1 = UQ112(储备量0 / 储备量1) * 时间流逝
            // 计算得到的值在用于价格预言机中使用
            price0CumulativeLast += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        //将余额0,余额1分别复制给储备量0,储备量1
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp; //更新时间戳
        emit Sync(reserve0, reserve1); //触发同步事件
    }

    //如果打开税收,铸造流动性相当于1/6的增长sqrt(k)
    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo(); //获取工程合约中的收税地址
        feeOn = feeTo != address(0); //定义个bool，如果feeTo地址为0，表示不收费
        uint256 _kLast = kLast; // gas savings 恒定乘积做市商(x * y = k)上次收取费用的增长
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = Math.sqrt(uint256(_reserve0).mul(_reserve1)); //k2
                uint256 rootKLast = Math.sqrt(_kLast); //k1
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply.mul(rootK.sub(rootKLast)); //分子
                    uint256 denominator = rootK.mul(5).add(rootKLast); //分母
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity); //流动性>0; 将流动性铸造给feeTo地址
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 应该从执行重要安全检查的合同中调用此低级功能
    // param to : 这个地址表示计算处理的流动性代币数额将给到这个地址
    function mint(address to) external lock returns (uint256 liquidity) {
        //通过getReserves()获取到t0,t1的储备量
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings

        //根据ERC20合约，可以获得token0和token1当前合约地址中所拥有的余额
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        //amount0 = 余额0 - 储备0 ，表示本次带来的值
        //amount1 = 余额1 - 储备1 ，表示本次带来的值
        uint256 amount0 = balance0.sub(_reserve0);
        uint256 amount1 = balance1.sub(_reserve1);

        //计算流动性,根据是否开启税收给对应地址发送协议费用
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 获取totalSupply; gas 节省，必须在这里定义，因为 totalSupply 可以在 _mintFee 中更新
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            //流动性 = (数量0 * 数量1)的平方根 - 最小流动性1000
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            //在总量为0的初始状态,永久锁定最低流动性(将它们发送到零地址，而不是发送到铸造者。)
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED'); // 校验流动性 > 0
        _mint(to, liquidity); // 铸造流动性发送给to地址

        _update(balance0, balance1, _reserve0, _reserve1); // 更新储备量

        // 如果铸造费开关为true, k值 = 储备0 * 储备1
        if (feeOn) kLast = uint256(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1); // 触发铸造事件
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 此低级功能应从执行重要安全检查的合同中调用
    // 外部调用 external
    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        // 获取储备量
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings

        // 获取当前调用者地址在token0, token1的代币余额
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));

        //获取当前调用者地址的流动性
        uint256 liquidity = balanceOf[address(this)];

        //计算税收费用
        bool feeOn = _mintFee(_reserve0, _reserve1);

        // 节省gas，必须在此处定义，因为totalSupply可以在_mintFee中更新
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee

        // 使用余额确保按比例分配（取出的数值 = 我所拥有的流动性占比 * 总余额）
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution

        //检查取出余额都大于0
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');

        //销毁方法,为当前合约地址销毁流动性
        _burn(address(this), liquidity);

        // 调用安全发送方法，分别将t0取出的amount0和t1取出的amount1发送给to地址
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);

        // 取出当前地址在合约上t0和t1的余额
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1); // 更新储备量

        // 如果开启了收取协议费用，则 kLast = x * y
        if (feeOn) kLast = uint256(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date

        // 触发销毁事件
        // msg.sender 此时应该为路由合约地址
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 此低级功能应从执行重要安全检查的合同中调用
    // 外部调用
    // 防重入锁
    function swap(
        uint256 amount0Out, //需要取出余额0数额
        uint256 amount1Out, //需要取出余额1数额
        address to, //取出存放的地址
        bytes calldata data // 存储的函数参数，只读。外部函数的参数（不包括返回参数）被强制为calldata
    ) external lock {
        // 校验取出数额0 或者 数额1其中一个大于 0
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');

        // 获取储备量0和储备量1
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings

        // 校验取出数额0小于储备量0  &&  取出数额1小于储备量1
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint256 balance0;
        uint256 balance1;
        {
            // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO'); // 校验to地址不能是t0和t1的地址

            // 确认取出数额大于0 ，就分别将t0和t1的数额安全发送到to地址
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            //闪电贷
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);

            // 获取最新的t0和t1余额
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }

        //反推输入的数额; 根据取出的储备量, 原有储备量和最新的余额
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;

        // 确保任意一个输入数额大于0
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');

        {
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            // 调整后的余额 = 最新余额 - 扣税金额 （相当于乘以997/1000） 3属于流动性添加者的收益
            uint256 balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint256 balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
            require( // 校验是否进行了扣税计算
                balance0Adjusted.mul(balance1Adjusted) >= uint256(_reserve0).mul(_reserve1).mul(1000**2),
                'UniswapV2: K'
            );
        }
        // 更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        // 触发交换事件
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    // 强制余额与准备金匹配(按照储备量去匹配余额)
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings

        // 多余储备量的金额发送给to地址
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    // 强制准备金与余额匹配(按照余额去匹配储备量)
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
