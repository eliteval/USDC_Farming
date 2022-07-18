//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

interface IToken {
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    function mint(address to, uint256 value) external returns (bool);

    function transfer(address to, uint256 value) external returns (bool);

    function balanceOf(address who) external view returns (uint256);

    function decimals() external view returns (uint256);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function approve(address spender, uint256 value) external returns (bool);
}

contract Ownable {
    address public owner;
    address proxy;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /**
     * @dev The Ownable constructor sets the original `owner` of the contract to the sender
     * account.
     */
    constructor() public {
        owner = msg.sender;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(msg.sender == owner || msg.sender == proxy);
        _;
    }

    /**
     * @dev Allows the current owner to transfer control of the contract to a newOwner.
     * @param newOwner The address to transfer ownership to.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0));
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setProxy(address _addr) public onlyOwner {
        proxy = _addr;
    }
}

library SafeMath {
    /**
     * @dev Multiplies two numbers, throws on overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256 c) {
        if (a == 0) {
            return 0;
        }
        c = a * b;
        assert(c / a == b);
        return c;
    }

    /**
     * @dev Integer division of two numbers, truncating the quotient.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        // assert(b > 0); // Solidity automatically throws when dividing by 0
        // uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold
        return a / b;
    }

    /**
     * @dev Subtracts two numbers, throws on overflow (i.e. if subtrahend is greater than minuend).
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        assert(b <= a);
        return a - b;
    }

    /* @dev Subtracts two numbers, else returns zero */
    function safeSub(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b > a) {
            return 0;
        } else {
            return a - b;
        }
    }

    /**
     * @dev Adds two numbers, throws on overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256 c) {
        c = a + b;
        assert(c >= a);
        return c;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract Farming is Ownable {
    using SafeMath for uint256;

    //Node types
    struct NodeType {
        string name;
        uint256 deposit_amount;
        uint256 daily_yield; // unit - 0.1%
    }
    mapping(uint256 => NodeType) public node_types;

    struct UserNode {
        //referral system
        address upline;
        uint256 direct_bonus;
        //Deposit Accounting
        uint256 deposits;
        uint256 deposit_time;
        uint256 created_time; //first deposit time
        //Payout and Roll Accounting
        uint256 payouts;
    }

    mapping(address => mapping(uint256 => UserNode)) public user_nodes;

    address POLYGON_USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;

    IToken private iToken;

    address public treasury_address;
    address public tax_wallet;
    uint256 public treasury_allocation = 35; //35% of deposit will go to treasury
    uint256 public referral_fee = 5; //5% of deposit amount to referrer
    uint256 public claim_fee = 10; //10% of claim amount for node before 1 month
    uint256 public max_bonus = 50 * 1e18; //limit of bonus for upline

    uint256 public total_users = 1; //set initial user - owner
    uint256 public total_deposited;
    uint256 public total_withdraw;

    event NewDeposit(address indexed addr, uint256 node_type, uint256 amount);
    event Claim(address indexed addr, uint256 node_type, uint256 amount);
    event DirectBonus(
        address indexed addr,
        address indexed from,
        uint256 amount
    );
    event Upline(address indexed addr, address indexed upline);

    constructor() Ownable() {
        iToken = IToken(POLYGON_USDC); // Polygon - USDC contract
        //Initialize three nodes
        node_types[0] = NodeType("Starter", 100 * 1e18, 2); //daily yield - 0.2%
        node_types[1] = NodeType("Pro", 500 * 1e18, 5); //daily yield - 0.5%
        node_types[2] = NodeType("Whale", 1000 * 1e18, 7); //daily yield - 0.7%
    }

    //User deposits with upline referrer
    function deposit(uint256 _node_type, address _upline) public {
        require(
            _node_type == 0 || _node_type == 1 || _node_type == 2,
            "Node Type Index should be 0 or 1 or 2"
        );
        address _addr = msg.sender;
        uint256 _amount = node_types[_node_type].deposit_amount;

        uint256 amount_to_treasury = _amount.mul(treasury_allocation).div(100);
        uint256 amount_to_contract = _amount.safeSub(amount_to_treasury);

        //Transfer Token to the contract
        require(
            iToken.transferFrom(_addr, address(this), amount_to_contract),
            "token transfer failed"
        );
        require(
            iToken.transferFrom(
                _addr,
                address(treasury_address),
                amount_to_treasury
            ),
            "token transfer failed"
        );

        _setUpline(_addr, _node_type, _upline);
        _deposit(_addr, _node_type, _amount);

        emit NewDeposit(_addr, _node_type, _amount);
    }

    // Set deposit variable
    function _deposit(
        address _addr,
        uint256 _node_type,
        uint256 _amount
    ) internal {
        //User's deposits
        user_nodes[_addr][_node_type].deposits += _amount;
        if (user_nodes[_addr][_node_type].deposit_time == 0)
            user_nodes[_addr][_node_type].created_time = block.timestamp;
        user_nodes[_addr][_node_type].deposit_time = block.timestamp;

        //Upline's bonus
        uint256 _bonus = _amount.mul(referral_fee).div(100).min(max_bonus);
        address _up = user_nodes[_addr][_node_type].upline;
        if (_up != _addr && _up != address(0)) {
            user_nodes[_up][_node_type].direct_bonus += _bonus;
            user_nodes[_up][_node_type].deposits += _bonus;
            emit DirectBonus(_up, _addr, _bonus);
        }

        total_deposited += _amount;
    }

    //Set upline varaiable
    function _setUpline(
        address _addr,
        uint256 _node_type,
        address _upline
    ) internal {
        //If upline is not self address and zero address
        if (_upline != _addr && _upline != address(0)) {
            user_nodes[_addr][_node_type].upline = _upline;
            emit Upline(_addr, _upline);

            //Update total users
            total_users++;
        }
    }

    // User can claim all of available nodes
    function claim_all() public {
        address _addr = msg.sender;
        if (checkNodeAvailable(_addr, 0))
            _claim(_addr, 0, getCurrentYield(_addr, 0));
        if (checkNodeAvailable(_addr, 1))
            _claim(_addr, 1, getCurrentYield(_addr, 1));
        if (checkNodeAvailable(_addr, 2))
            _claim(_addr, 2, getCurrentYield(_addr, 2));
    }

    //check node if that is after 1 month and before 12 months
    function checkNodeAvailable(address _addr, uint256 _node_type)
        internal
        view
        returns (bool)
    {
        if (
            block.timestamp <
            user_nodes[_addr][_node_type].created_time + 365 days &&
            block.timestamp >
            user_nodes[_addr][_node_type].deposit_time + 30 days &&
            user_nodes[_addr][_node_type].deposit_time > 0
        ) return true;
        else return false;
    }

    //User can claim for individual node
    function claim_one(uint256 _node_type, uint256 _amount) public {
        address _addr = msg.sender;
        _claim(_addr, _node_type, _amount);
    }

    function _claim(
        address _addr,
        uint256 _node_type,
        uint256 _amount
    ) public {
        require(_amount > 0, "Zero payout");
        require(
            _amount <= getCurrentYield(_addr, _node_type),
            "Amount is larger than current yield."
        );
        require(
            user_nodes[_addr][_node_type].deposit_time > 0,
            "Have to deposit first"
        );
        require(
            block.timestamp >
                user_nodes[_addr][_node_type].created_time + 30 days,
            "Can not claim during first 30 days"
        );
        require(
            block.timestamp <
                user_nodes[_addr][_node_type].created_time + 365 days,
            "This node is expired."
        );
        //Treasury will refill if balance is not enough
        uint256 this_balance = iToken.balanceOf(address(this));
        if (this_balance < _amount) {
            uint256 difference_amount = _amount.sub(this_balance);
            require(
                iToken.transferFrom(
                    treasury_address,
                    address(this),
                    difference_amount
                ),
                "token transfer failed"
            );
        }
        //Apply fee if user claims before 1 month
        uint256 fee_percent = 0;
        if (
            block.timestamp <
            user_nodes[_addr][_node_type].deposit_time + 30 days
        ) fee_percent = claim_fee;
        //Transfer tokens
        uint256 fee = _amount.mul(claim_fee).div(100);
        uint256 realizedPayout = _amount.safeSub(fee);
        require(iToken.transfer(_addr, realizedPayout));
        require(iToken.transfer(tax_wallet, fee));

        //update payout, roll for rest amount
        user_nodes[_addr][_node_type].payouts += _amount;
        user_nodes[_addr][_node_type].deposits += getCurrentYield(
            _addr,
            _node_type
        ).safeSub(_amount);

        user_nodes[_addr][_node_type].deposit_time = block.timestamp;

        emit Claim(_addr, _node_type, _amount);

        //update total withdraw
        total_withdraw += _amount;
    }

    // Calculate the current yield that use can claim
    function getCurrentYield(address _addr, uint256 _node_type)
        public
        view
        returns (uint256 payout)
    {
        uint256 share = user_nodes[_addr][_node_type]
            .deposits
            .mul(node_types[_node_type].daily_yield * 1e18)
            .div(1000e18)
            .div(24 hours);
        payout =
            share *
            block.timestamp.safeSub(user_nodes[_addr][_node_type].deposit_time);
    }

    //Get number of nodes user has
    function getNodesCount(address _addr)
        public
        view
        returns (uint256, bool[] memory)
    {
        uint256 count = 0;
        bool[] memory status = new bool[](3);
        for (uint256 i = 0; i < 3; i++) {
            if (user_nodes[_addr][i].deposits > 0) {
                count++;
                status[i] = true;
            } else status[i] = false;
        }
        return (count, status);
    }

    //Get remaining time for claim
    function getRemainingTimes(address _addr)
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory remainings = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            uint256 rr = user_nodes[_addr][i].deposit_time +
                30 days -
                block.timestamp;
            remainings[i] = rr;
        }
        return (remainings);
    }

    //Get User's total deposit
    function getUserDeposit(address _addr) public view returns (uint256) {
        uint256 sum = 0;
        for (uint256 i = 0; i < 3; i++) {
            sum += user_nodes[_addr][i].deposits;
        }
        return sum;
    }

    //Get User's total withdraw
    function getUserWithdraw(address _addr) public view returns (uint256) {
        uint256 sum = 0;
        for (uint256 i = 0; i < 3; i++) {
            sum += user_nodes[_addr][i].payouts;
        }
        return sum;
    }

    //Admin side function
    function setStablecoinAddress(address _tokenadd) public onlyOwner {
        iToken = IToken(_tokenadd);
    }

    function setTreasuryAddress(address _treasuryadd) public onlyOwner {
        treasury_address = _treasuryadd;
    }

    function setTaxWallet(address addr) public onlyOwner {
        tax_wallet = addr;
    }

    function setReferralFee(uint256 fee) public onlyOwner {
        referral_fee = fee;
    }

    function setCalimFee(uint256 fee) public onlyOwner {
        claim_fee = fee;
    }

    function setTreasuryAllocation(uint256 _treasuryallocation)
        public
        onlyOwner
    {
        require(_treasuryallocation < 100, "should be less than 100.");
        treasury_allocation = _treasuryallocation;
    }

    function updateNodeType(
        uint256 _node_type,
        string memory name,
        uint256 deposit_amount,
        uint256 daily_yield
    ) public onlyOwner {
        require(
            _node_type == 0 || _node_type == 1 || _node_type == 2,
            "Node Type Index should be 0 or 1 or 2"
        );
        node_types[_node_type] = NodeType(name, deposit_amount, daily_yield);
    }
}
