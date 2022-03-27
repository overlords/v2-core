pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

//声明工厂合约
contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo;       //收税地址
    address public feeToSetter; //收税权限地址

    //配对合约映射
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    //创建配对合约事件
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);
    
    //构造方法; 初始化收税地址
    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    //获取所有的配对合约数量
    //返回数组allPairs的长度
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    //创建配对合约
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES'); //配对的2个合约不能是同一个地址

        //对tokenA，tokenB进行排序；保证tokenA<tokenB
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS'); //判断合约地址不能为0;
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient // 进行一次检查合约是否已经创建配对
        
        //引入UniswapV2Pair配对合约,未使用继承方式
        //使用type获取配对合约(UniswapV2Pair)编译后(creationCode)的字节码
        bytes memory bytecode = type(UniswapV2Pair).creationCode;

        //制作一个盐(salt)
        //1.使用encodePacked对参数token0和token1进行紧打包编码
        //2.keccak256对(1)进行hash加密
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        
        //内联汇编
        //mload(bytecode) 字节码长度
        //add(bytecode, 32) 增加字节码空间32
        //create2 用 mem[p...(p + s)) 中的代码，在地址 keccak256(<address> . n . keccak256(mem[p...(p + s))) 上 创建新合约、发送 v wei 并返回新地址
        assembly {
            //通过create2方法部署合约,添加盐,返回新的合约地址给pair
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        //对pair配对合约进行实例化
        IUniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction //双向合约地址映射，方便查找配对合约
        allPairs.push(pair);    //添加到所有配对合约数组
        //出发合约配对成功事件
        emit PairCreated(token0, token1, pair, allPairs.length);
    }
    // @title 设置收税地址
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }
    
    //设置收税权限
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
