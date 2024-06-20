pragma solidity 0.8.20;
pragma abicoder v2;
import "./safemath.sol";
import "./IERC20.sol";

contract ImprovedDex {

    using SafeMath for uint256;

    address owner;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner {
        require(msg.sender == owner);
        _;
    }

    struct Token {
	    string ticker;
	    address tokenAddress;
    }

    mapping (address => mapping (string => uint256)) public tokenBalances;

    mapping (string => Token) public tokenMapping;

    string[] public tokenList;

    modifier tokenExist (string memory _ticker) {
        require(tokenMapping[_ticker].tokenAddress != address(0), "Unsupported token.");
        _;
    }

    enum Side {
        BUY,
        SELL
    }

    struct Order {
        uint256 id;
        address trader;
        Side side;
        string ticker;
        uint256 price;
        uint256 amount;
        uint256 filled;
    }

    mapping(string => mapping(uint256 => Order[])) public orderBook;

    uint256 public nextOrderId = 0;

    event transferCompleted(address _from, address _to, uint256 _value);
    event tradeCompleted (uint256 tradeId, string ticker, uint256 _orderQty, uint256 _orderPrice, uint256 tradeCost, address buyer, address seller);

    function addToken(string memory _ticker, address _tokenAddress) external onlyOwner {
	    tokenMapping[_ticker] = Token(_ticker, _tokenAddress);
	    tokenList.push(_ticker);
    }

    function tokenDeposit(string memory _ticker, uint256 _amount) external tokenExist(_ticker) {
        uint256 previousTokenBalance = tokenBalances[msg.sender][_ticker];
        IERC20(tokenMapping[_ticker].tokenAddress).transferFrom(msg.sender, address(this), _amount);
        tokenBalances[msg.sender][_ticker] = tokenBalances[msg.sender][_ticker].add(_amount);
        emit transferCompleted(msg.sender, address(this), _amount);
        assert(tokenBalances[msg.sender][_ticker] == previousTokenBalance.add(_amount));
    }

    function tokenWithdrawal(string memory _ticker, uint256 _amount) external tokenExist(_ticker) {
        require(tokenBalances[msg.sender][_ticker] >= _amount, 'Balance not sufficient.');
        uint256 previousTokenBalance = tokenBalances[msg.sender][_ticker];
	    tokenBalances[msg.sender][_ticker] = tokenBalances[msg.sender][_ticker].sub(_amount);
	    IERC20(tokenMapping[_ticker].tokenAddress).transfer(payable(msg.sender), _amount);
        emit transferCompleted(address(this), msg.sender, _amount);
        assert(tokenBalances[msg.sender][_ticker] == previousTokenBalance.sub(_amount));
    }

    function ethDeposit() payable external {
        tokenBalances[msg.sender]["ETH"] = tokenBalances[msg.sender]["ETH"].add(msg.value);
    }
    
    function ethWithdraw(uint _amount) external {
        require(tokenBalances[msg.sender]["ETH"] >= _amount,'Balance not sufficient.'); 
        tokenBalances[msg.sender]["ETH"] = tokenBalances[msg.sender]["ETH"].sub(_amount);
        msg.sender.call{value:_amount}("");
    }

    function getOrderBook(string memory _ticker, Side _side) public view returns(Order[] memory) {
        return orderBook[_ticker][uint(_side)];
    }

    function createLimitOrder(string memory _ticker, Side _side, uint256 _orderQty, uint256 _orderPrice) public returns(uint256 _filledQty) {
        uint256 actuallyFilled = 0;
        Order[] storage buyorders = orderBook[_ticker][uint(0)];
        Order[] storage sellorders = orderBook[_ticker][uint(1)];
        if(_side == Side.BUY){
            require(tokenBalances[msg.sender]["ETH"] >= _orderQty.mul(_orderPrice), "Your ETH balance is insufficient for this buy limit order.");
            if(sellorders.length == 0){
                buyorders.push(Order(nextOrderId, msg.sender, _side, _ticker, _orderPrice, _orderQty, 0));
                //bubble sort orders by price, [3, 2, 1]
                uint256 bsp = buyorders.length > 0 ? buyorders.length.sub(1) : 0;
                while(bsp > 0){
                    if(buyorders[bsp.sub(1)].price >= buyorders[bsp].price) {
                        break;
                    }
                    Order memory temp = buyorders[bsp.sub(1)];
                    buyorders[bsp.sub(1)] = buyorders[bsp];
                    buyorders[bsp] = temp;
                    bsp--;
                }
                orderBook[_ticker][uint(0)] = buyorders;
                nextOrderId++;
                return actuallyFilled;
            }
            else{
                if(sellorders[0].price <= _orderPrice){
                    uint256 leftToFill = _orderQty;
                    uint256 filledByThisTrade = 0;
                    uint256 costOfThisTrade = 0;
                    for (uint256 i = 0; i < sellorders.length && actuallyFilled < _orderQty; i++) {
                        if(sellorders[i].price <= _orderPrice && sellorders[i].amount.sub(sellorders[i].filled) >= leftToFill){
                            filledByThisTrade = leftToFill;
                        }
                        else if(sellorders[i].price <= _orderPrice && sellorders[i].amount.sub(sellorders[i].filled) < leftToFill){ 
                            filledByThisTrade = sellorders[i].amount.sub(sellorders[i].filled);
                        }
                        else{
                            filledByThisTrade = 0;
                        }
                        sellorders[i].filled = sellorders[i].filled.add(filledByThisTrade);
                        costOfThisTrade = filledByThisTrade.mul(sellorders[i].price);
                        if(filledByThisTrade == 0){
                            break;
                        }
                        else if(tokenBalances[sellorders[i].trader][_ticker] < filledByThisTrade){
                                sellorders[i].filled = sellorders[i].amount;
                        }
                        else{
                            require(tokenBalances[msg.sender]["ETH"] >= costOfThisTrade, "You don't have enough ETH for this trade.");
                            require(sellorders[i].trader != msg.sender, "You currently have sell limit orders in place that would be triggered by this buy limit order.");
                            tokenBalances[msg.sender][_ticker] = tokenBalances[msg.sender][_ticker].add(filledByThisTrade);
                            tokenBalances[msg.sender]["ETH"] = tokenBalances[msg.sender]["ETH"].sub(costOfThisTrade);
                            tokenBalances[sellorders[i].trader][_ticker] = tokenBalances[sellorders[i].trader][_ticker].sub(filledByThisTrade);
                            tokenBalances[sellorders[i].trader]["ETH"] = tokenBalances[sellorders[i].trader]["ETH"].add(costOfThisTrade);
                            actuallyFilled = actuallyFilled.add(filledByThisTrade);
                            leftToFill = leftToFill.sub(filledByThisTrade);
                            emit tradeCompleted(sellorders[i].id, _ticker, sellorders[i].filled, sellorders[i].price, costOfThisTrade, msg.sender, sellorders[i].trader);
                        }
                    }
                    while(sellorders.length > 0 && sellorders[0].filled == sellorders[0].amount){
                        for (uint256 i = 0; i < sellorders.length.sub(1); i++) {
                            sellorders[i] = sellorders[i.add(1)];
                        }
                        sellorders.pop();
                    }
                    orderBook[_ticker][uint(1)] = sellorders;
                    if(leftToFill > 0){
                        buyorders.push(Order(nextOrderId, msg.sender, _side, _ticker, _orderPrice, leftToFill, 0));
                        //bubble sort orders by price, [3, 2, 1]
                        uint256 bsp = buyorders.length > 0 ? buyorders.length.sub(1) : 0;
                        while(bsp > 0){
                            if(buyorders[bsp.sub(1)].price >= buyorders[bsp].price) {
                                break;
                            }
                            Order memory temp = buyorders[bsp.sub(1)];
                            buyorders[bsp.sub(1)] = buyorders[bsp];
                            buyorders[bsp] = temp;
                            bsp--;
                        }
                        orderBook[_ticker][uint(0)] = buyorders;
                        nextOrderId++;
                    }
                    return actuallyFilled;
                }
                else{
                    buyorders.push(Order(nextOrderId, msg.sender, _side, _ticker, _orderPrice, _orderQty, 0));
                    //bubble sort orders by price, [3, 2, 1]
                    uint256 bsp = buyorders.length > 0 ? buyorders.length.sub(1) : 0;
                    while(bsp > 0){
                        if(buyorders[bsp.sub(1)].price >= buyorders[bsp].price) {
                            break;
                        }
                        Order memory temp = buyorders[bsp.sub(1)];
                        buyorders[bsp.sub(1)] = buyorders[bsp];
                        buyorders[bsp] = temp;
                        bsp--;
                    }
                    orderBook[_ticker][uint(0)] = buyorders;
                    nextOrderId++;
                    return actuallyFilled;
                }
            }
        }
        else if(_side == Side.SELL){
            require(tokenBalances[msg.sender][_ticker] >= _orderQty, "Your token balance is insufficient for this sell limit order.");
            if(buyorders.length == 0){
                sellorders.push(Order(nextOrderId, msg.sender, _side, _ticker, _orderPrice, _orderQty, 0));
                //bubble sort orders by price, [1, 2, 3]
                uint256 bsp = sellorders.length > 0 ? sellorders.length.sub(1) : 0;
                while(bsp > 0){
                    if(sellorders[bsp.sub(1)].price <= sellorders[bsp].price) {
                        break;   
                    }
                    Order memory temp = sellorders[bsp.sub(1)];
                    sellorders[bsp.sub(1)] = sellorders[bsp];
                    sellorders[bsp] = temp;
                    bsp--;
                }
                orderBook[_ticker][uint(0)] = buyorders;
                nextOrderId++;
                return actuallyFilled;
            }
            else{
                if(buyorders[0].price >= _orderPrice){
                    uint256 leftToFill = _orderQty;
                    uint256 filledByThisTrade = 0;
                    uint256 costOfThisTrade = 0;
                    for (uint256 i = 0; i < buyorders.length && actuallyFilled < _orderQty; i++) {
                        if(buyorders[i].price >= _orderPrice && buyorders[i].amount.sub(buyorders[i].filled) >= leftToFill){
                            filledByThisTrade = leftToFill;
                        }
                        else if(buyorders[i].price >= _orderPrice && buyorders[i].amount.sub(buyorders[i].filled) < leftToFill){ 
                            filledByThisTrade = buyorders[i].amount.sub(buyorders[i].filled);
                        }
                        else{
                            filledByThisTrade = 0;
                        }
                        buyorders[i].filled = buyorders[i].filled.add(filledByThisTrade);
                        costOfThisTrade = filledByThisTrade.mul(buyorders[i].price);
                        if(filledByThisTrade == 0){
                            break;
                        }
                        else if(tokenBalances[buyorders[i].trader]["ETH"] < costOfThisTrade){
                            buyorders[i].filled = buyorders[i].amount;
                        }
                        else{
                            require(buyorders[i].trader != msg.sender, "You currently have buy limit orders in place that would be triggered by this sell limit order.");
                            tokenBalances[msg.sender][_ticker] = tokenBalances[msg.sender][_ticker].sub(filledByThisTrade);
                            tokenBalances[msg.sender]["ETH"] = tokenBalances[msg.sender]["ETH"].add(costOfThisTrade);
                            tokenBalances[buyorders[i].trader][_ticker] = tokenBalances[buyorders[i].trader][_ticker].add(filledByThisTrade);
                            tokenBalances[buyorders[i].trader]["ETH"] = tokenBalances[buyorders[i].trader]["ETH"].sub(costOfThisTrade);
                            actuallyFilled = actuallyFilled.add(filledByThisTrade);
                            leftToFill = leftToFill.sub(filledByThisTrade);
                            emit tradeCompleted(buyorders[i].id, _ticker, buyorders[i].filled, buyorders[i].price, costOfThisTrade, msg.sender, buyorders[i].trader);
                        }
                    }
                    while(buyorders.length > 0 && buyorders[0].filled == buyorders[0].amount){
                        for (uint256 i = 0; i < buyorders.length.sub(1); i++) {
                            buyorders[i] = buyorders[i.add(1)];
                        }
                        buyorders.pop();
                    }
                    orderBook[_ticker][uint(0)] = buyorders;
                    if(leftToFill > 0){
                    sellorders.push(Order(nextOrderId, msg.sender, _side, _ticker, _orderPrice, leftToFill, 0));
                    //bubble sort orders by price, [1, 2, 3]
                    uint256 bsp = sellorders.length > 0 ? sellorders.length.sub(1) : 0;
                    while(bsp > 0){
                        if(sellorders[bsp.sub(1)].price <= sellorders[bsp].price) {
                            break;   
                        }
                        Order memory temp = sellorders[bsp.sub(1)];
                        sellorders[bsp.sub(1)] = sellorders[bsp];
                        sellorders[bsp] = temp;
                        bsp--;
                    }
                    orderBook[_ticker][uint(0)] = buyorders;
                    nextOrderId++;
                    }
                    return actuallyFilled;
                }
                else{
                    sellorders.push(Order(nextOrderId, msg.sender, _side, _ticker, _orderPrice, _orderQty, 0));
                    //bubble sort orders by price, [1, 2, 3]
                    uint256 bsp = sellorders.length > 0 ? sellorders.length.sub(1) : 0;
                    while(bsp > 0){
                        if(sellorders[bsp.sub(1)].price <= sellorders[bsp].price) {
                            break;   
                        }
                        Order memory temp = sellorders[bsp.sub(1)];
                        sellorders[bsp.sub(1)] = sellorders[bsp];
                        sellorders[bsp] = temp;
                        bsp--;
                    }
                    orderBook[_ticker][uint(0)] = buyorders;
                    nextOrderId++;
                    return actuallyFilled;
                }
            }
        }
    }

    function createMarketOrder(string memory _ticker, Side _side, uint256 _orderQty) public returns(uint256 _filledQty) {
        uint256 actuallyFilled = 0;
        uint orderBookSide;
        if(_side == Side.SELL){
            require(tokenBalances[msg.sender][_ticker] >= _orderQty, "Your token balance is insufficient for this sell market order.");
            orderBookSide = 0;
        }
        else{
            orderBookSide = 1;
        }
        Order[] storage orders = orderBook[_ticker][orderBookSide];
        require(orders.length !=0, "There is currently no liquidity for this token on this trade side.");
        uint256 leftToFill = _orderQty;
        uint256 filledByThisTrade = 0;
        uint256 costOfThisTrade = 0;
        for (uint256 i = 0; i < orders.length && actuallyFilled < _orderQty; i++) {
            if(orders[i].amount.sub(orders[i].filled) > leftToFill){
                filledByThisTrade = leftToFill;
            }
            else{ 
                filledByThisTrade = orders[i].amount.sub(orders[i].filled);
            }
            orders[i].filled = orders[i].filled.add(filledByThisTrade);
            costOfThisTrade = filledByThisTrade.mul(orders[i].price);
            if(_side == Side.BUY){
                if(tokenBalances[orders[i].trader][_ticker] < filledByThisTrade){
                        orders[i].filled = orders[i].amount;
                }
                else{
                    require(tokenBalances[msg.sender]["ETH"] >= costOfThisTrade, "You don't have enough ETH for this trade.");
                    require(orders[i].trader != msg.sender, "You currently have limit orders in place that would be triggered by this market order.");
                    tokenBalances[msg.sender][_ticker] = tokenBalances[msg.sender][_ticker].add(filledByThisTrade);
                    tokenBalances[msg.sender]["ETH"] = tokenBalances[msg.sender]["ETH"].sub(costOfThisTrade);
                    tokenBalances[orders[i].trader][_ticker] = tokenBalances[orders[i].trader][_ticker].sub(filledByThisTrade);
                    tokenBalances[orders[i].trader]["ETH"] = tokenBalances[orders[i].trader]["ETH"].add(costOfThisTrade);
                    actuallyFilled = actuallyFilled.add(filledByThisTrade);
                    leftToFill = leftToFill.sub(filledByThisTrade);
                    emit tradeCompleted(orders[i].id, _ticker, orders[i].filled, orders[i].price, costOfThisTrade, msg.sender, orders[i].trader);
                }
            }
            else if(_side == Side.SELL){
                if(tokenBalances[orders[i].trader]["ETH"] < costOfThisTrade){
                        orders[i].filled = orders[i].amount;
                }
                else{
                    require(orders[i].trader != msg.sender, "You currently have limit orders in place that would be triggered by this market order.");
                    tokenBalances[msg.sender][_ticker] = tokenBalances[msg.sender][_ticker].sub(filledByThisTrade);
                    tokenBalances[msg.sender]["ETH"] = tokenBalances[msg.sender]["ETH"].add(costOfThisTrade);
                    tokenBalances[orders[i].trader][_ticker] = tokenBalances[orders[i].trader][_ticker].add(filledByThisTrade);
                    tokenBalances[orders[i].trader]["ETH"] = tokenBalances[orders[i].trader]["ETH"].sub(costOfThisTrade);
                    actuallyFilled = actuallyFilled.add(filledByThisTrade);
                    leftToFill = leftToFill.sub(filledByThisTrade);
                    emit tradeCompleted(orders[i].id, _ticker, orders[i].filled, orders[i].price, costOfThisTrade, msg.sender, orders[i].trader);
                }
            }
        }
        while(orders.length > 0 && orders[0].filled == orders[0].amount){
            for (uint256 i = 0; i < orders.length.sub(1); i++) {
                orders[i] = orders[i.add(1)];
            }
            orders.pop();
        }
        orderBook[_ticker][orderBookSide] = orders;
        return actuallyFilled;
    }

    function _popOrderBook(string memory _ticker, Side _side) public {
        Order[] storage orders = orderBook[_ticker][uint(_side)];
        orders.pop();
    }
}
