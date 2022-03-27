
//指定solidity编译版本
pragma solidity =0.5.16;

import './interfaces/IUniswapV2ERC20.sol';  //导入 IUniswapV2ERC20 接口
import './libraries/SafeMath.sol';  //导入 SafeMath 安全库

//定义合约UniswapV2ERC20 继续自 IUniswapV2ERC20
contract UniswapV2ERC20 is IUniswapV2ERC20 {
    using SafeMath for uint;    //使用safeMath中uint  在solidity8.0+版本无需使用safemath

    string public constant name = 'Uniswap V2'; //定义代币合约名称
    string public constant symbol = 'UNI-V2';   //定义代币简称
    uint8 public constant decimals = 18;        //定义代币小数位长度
    uint  public totalSupply;                   //定义代币发行总量
    mapping(address => uint) public balanceOf;  //存储这个代币的每个地址的余额
    mapping(address => mapping(address => uint)) public allowance;  //授权列表

    bytes32 public DOMAIN_SEPARATOR; // 用来在不同Dapp之间区分相同结构和内容的签名消息 ps.EIP-712
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    
    //根据事先约定使用permit函数的部分定义计算哈希值，重建消息签名时使用
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint) public nonces;

    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    constructor() public {
        uint chainId;
        assembly {
            chainId := chainid
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(name)),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );
    }

    function _mint(address to, uint value) internal {
        totalSupply = totalSupply.add(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint value) internal {
        balanceOf[from] = balanceOf[from].sub(value);
        totalSupply = totalSupply.sub(value);
        emit Transfer(from, address(0), value);
    }

    function _approve(address owner, address spender, uint value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(address from, address to, uint value) private {
        balanceOf[from] = balanceOf[from].sub(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }

    function approve(address spender, uint value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint value) external returns (bool) {
        if (allowance[from][msg.sender] != uint(-1)) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
        }
        _transfer(from, to, value);
        return true;
    }

    // permit使用线下签名消息进行授权操作
    //https://github.com/ethereum/EIPs/blob/master/EIPS/eip-712.md
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        //不能大于当前区块时间戳
        require(deadline >= block.timestamp, 'UniswapV2: EXPIRED');
        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'UniswapV2: INVALID_SIGNATURE');
        _approve(owner, spender, value);
    }
}
