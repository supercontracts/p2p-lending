// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAaveV3Pool } from "./interfaces/IAaveV3Pool.sol";

struct Bucket {
    uint64 head;  // Head order ID
    uint64 tail;  // Tail order ID
    uint32 count; // Number of orders
}

struct Order {
    address owner;
    uint16  rateBps;
    uint64  createdAt;
    uint128 amount;
    uint128 remaining;
    uint64  next;
    uint64  prev;
}

struct Loan {
    address lender;
    address borrower;
    uint128 principal;
    uint64  startTime;
    uint16  rateBps;
    bool    active;
}

contract MatchingEngine {

    /******************************************************************************************************************/
    /*** Errors                                                                                                     ***/
    /******************************************************************************************************************/

    error ZeroAmount();
    error InvalidRateIncrement();
    error RateTooHigh();
    error NotOwner();
    error NoRemaining();
    error LoanNotActive();
    error NotBorrower();
    error ZeroBalance();
    error AmountTooLarge();

    /******************************************************************************************************************/
    /*** Events                                                                                                     ***/
    /******************************************************************************************************************/

    event Matched(uint64 indexed lenderOrderId, uint64 indexed borrowerOrderId, uint256 rateBps, uint256 amount);
    event Repaid(uint64 indexed loanId, uint256 amount);
    event CanceledLend(uint64 indexed orderId, uint256 amount);
    event CanceledBorrow(uint64 indexed orderId);

    /******************************************************************************************************************/
    /*** State variables                                                                                             ***/
    /******************************************************************************************************************/

    IERC20      public immutable   token;
    IAaveV3Pool public immutable   aavePool;
    IERC20      internal immutable aToken;

    uint256 internal constant INCREMENT        = 25;
    uint256 internal constant BITS_PER_WORD    = 256;
    uint256 internal constant WORDS            = 4;        // Supports up to 1024 buckets (~25,600 bps)
    uint256 internal constant SECONDS_PER_YEAR = 31536000; // 365 * 86400

    // Lender structures (minRate, dequeue min)
    uint256[WORDS]             internal lender_bitmap;
    mapping(uint256 => Bucket) internal lender_buckets;
    mapping(uint256 => Order)  internal lender_orders;
    uint64                     internal lender_nextId = 1;

    // Borrower structures (maxRate, dequeue max)
    uint256[WORDS]             internal borrow_bitmap;
    mapping(uint256 => Bucket) internal borrow_buckets;
    mapping(uint256 => Order)  internal borrow_orders;
    uint64                     internal borrow_nextId = 1;

    // Loans
    mapping(uint256 => Loan) public loans;

    uint64 internal nextLoanId = 1;

    uint256 public totalUnmatchedPrincipal;

    /******************************************************************************************************************/
    /*** Constructor                                                                                                ***/
    /******************************************************************************************************************/

    /// @notice Deploys the matching engine and wires it to the ERC20 reserve and Aave pool
    /// @param _token ERC20 asset used for lending and borrowing
    /// @param _aavePool Aave v3 pool that custody unmatched liquidity
    constructor(address _token, address _aavePool) {
        token    = IERC20(_token);
        aavePool = IAaveV3Pool(_aavePool);

        IAaveV3Pool.ReserveData memory reserve = aavePool.getReserveData(_token);
        aToken = IERC20(reserve.aTokenAddress);

        token.approve(address(aavePool), type(uint256).max);
    }

    /******************************************************************************************************************/
    /*** Public functions                                                                                           ***/
    /******************************************************************************************************************/

    /// @notice Places a lender order and supplies the funds to Aave until matched
    /// @param amount Amount of tokens to lend (must fit in uint128)
    /// @param minRateBps Minimum acceptable borrow rate expressed in basis points
    function lend(uint256 amount, uint256 minRateBps) external {
        // Step 1: Validate input
        if (amount == 0) revert ZeroAmount();
        if (minRateBps % INCREMENT != 0) revert InvalidRateIncrement();
        if (amount > type(uint128).max) revert AmountTooLarge();

        // Step 2: Place order in the bucket
        uint256 bucketId = minRateBps / INCREMENT;
        if (bucketId >= WORDS * BITS_PER_WORD) revert RateTooHigh();

        uint64 id = lender_nextId++;
        lender_orders[id] = Order({
            owner     : msg.sender,
            rateBps   : uint16(minRateBps),
            createdAt : uint64(block.timestamp),
            amount    : uint128(amount),
            remaining : uint128(amount),
            next      : 0,
            prev      : 0
        });

        Bucket storage bucket = lender_buckets[bucketId];
        if (bucket.count == 0) {
            _setBit(lender_bitmap, bucketId);
        }
        if (bucket.tail == 0) {
            bucket.head = id;
            bucket.tail = id;
        } else {
            lender_orders[id].prev          = bucket.tail;
            lender_orders[bucket.tail].next = id;
            bucket.tail                     = id;
        }
        bucket.count++;

        // Step 3: Transfer tokens to the contract and supply to Aave
        token.transferFrom(msg.sender, address(this), amount);
        aavePool.supply(address(token), amount, address(this), 0);
        totalUnmatchedPrincipal += amount;
    }

    /// @notice Places a borrower order at a maximum acceptable rate
    /// @param amount Amount of tokens requested (must fit in uint128)
    /// @param maxRateBps Maximum rate the borrower is willing to pay in basis points
    function borrow(uint256 amount, uint256 maxRateBps) external {
        // Step 1: Validate input
        if (amount == 0) revert ZeroAmount();
        if (maxRateBps % INCREMENT != 0) revert InvalidRateIncrement();
        if (amount > type(uint128).max) revert AmountTooLarge();

        // Step 2: Place order in the bucket
        uint256 bucketId = maxRateBps / INCREMENT;
        if (bucketId >= WORDS * BITS_PER_WORD) revert RateTooHigh();

        uint64 id = borrow_nextId++;
        borrow_orders[id] = Order({
            owner     : msg.sender,
            rateBps   : uint16(maxRateBps),
            createdAt : uint64(block.timestamp),
            amount    : uint128(amount),
            remaining : uint128(amount),
            next      : 0,
            prev      : 0
        });

        Bucket storage bucket = borrow_buckets[bucketId];
        if (bucket.count == 0) {
            _setBit(borrow_bitmap, bucketId);
        }
        if (bucket.tail == 0) {
            bucket.head = id;
            bucket.tail = id;
        } else {
            borrow_orders[id].prev = bucket.tail;
            borrow_orders[bucket.tail].next = id;
            bucket.tail = id;
        }
        bucket.count++;
    }

    /// @notice Attempts to match the best available lender and borrower orders up to a provided limit
    /// @param maxItems Maximum number of matches to perform in this call
    function matchOrder(uint256 maxItems) external {
        uint256 items = 0;
        while (items < maxItems) {
            uint256 lBucketId = _findLowestSetBit(lender_bitmap);
            if (lBucketId == type(uint256).max) break;

            uint256 bBucketId = _findHighestSetBit(borrow_bitmap);
            if (bBucketId == type(uint256).max) break;

            Bucket storage lBucket = lender_buckets[lBucketId];
            uint64 lId = lBucket.head;
            Order storage lOrder = lender_orders[lId];

            Bucket storage bBucket = borrow_buckets[bBucketId];
            uint64 bId = bBucket.head;
            Order storage bOrder = borrow_orders[bId];

            if (lOrder.rateBps > bOrder.rateBps) break;

            uint128 fillAmt = _min(lOrder.remaining, bOrder.remaining);

            aavePool.withdraw(address(token), uint256(fillAmt), bOrder.owner);
            totalUnmatchedPrincipal -= uint256(fillAmt);

            uint16 rateBps = (lOrder.rateBps + bOrder.rateBps) / 2;
            uint64 loanId  = nextLoanId++;
            loans[loanId]  = Loan(lOrder.owner, bOrder.owner, fillAmt, uint64(block.timestamp), rateBps, true);

            emit Matched(lId, bId, uint256(rateBps), uint256(fillAmt));

            lOrder.remaining -= fillAmt;
            bOrder.remaining -= fillAmt;

            if (lOrder.remaining == 0) {
                lBucket.head = lOrder.next;
                if (lBucket.head != 0) lender_orders[lBucket.head].prev = 0;
                lBucket.count--;
                if (lBucket.count == 0) {
                    _clearBit(lender_bitmap, lBucketId);
                    lBucket.tail = 0;
                }
                delete lender_orders[lId];
            }

            if (bOrder.remaining == 0) {
                bBucket.head = bOrder.next;
                if (bBucket.head != 0) borrow_orders[bBucket.head].prev = 0;
                bBucket.count--;
                if (bBucket.count == 0) {
                    _clearBit(borrow_bitmap, bBucketId);
                    bBucket.tail = 0;
                }
                delete borrow_orders[bId];
            }

            items++;
        }
    }

    /// @notice Cancels an outstanding lender order, withdrawing principal plus accrued interest
    /// @param id Identifier of the lender order to cancel
    function cancelLend(uint64 id) external {
        Order storage order = lender_orders[id];
        if (order.owner != msg.sender) revert NotOwner();

        uint128 remaining = order.remaining;
        if (remaining == 0) revert NoRemaining();

        uint256 currentBalance  = aToken.balanceOf(address(this)) + IERC20(token).balanceOf(address(this));
        uint256 totalAccrued    = totalUnmatchedPrincipal == 0 ? 0 : currentBalance - totalUnmatchedPrincipal;
        uint256 proRataInterest = totalUnmatchedPrincipal == 0 ? 0 : (uint256(remaining) * totalAccrued) / totalUnmatchedPrincipal;
        uint256 toWithdraw      = uint256(remaining) + proRataInterest;

        totalUnmatchedPrincipal -= uint256(remaining);

        uint256 bucketId = uint256(order.rateBps) / INCREMENT; // Since rateBps is minRateBps
        Bucket storage bucket = lender_buckets[bucketId];

        uint64 prevId = order.prev;
        uint64 nextId = order.next;

        if (prevId == 0) {
            bucket.head = nextId;
        } else {
            lender_orders[prevId].next = nextId;
        }
        if (nextId != 0) {
            lender_orders[nextId].prev = prevId;
        }
        if (bucket.tail == id) {
            bucket.tail = prevId;
        }
        bucket.count--;
        if (bucket.count == 0) {
            _clearBit(lender_bitmap, bucketId);
        }

        delete lender_orders[id];

        aavePool.withdraw(address(token), toWithdraw, msg.sender);

        emit CanceledLend(id, toWithdraw);
    }

    /// @notice Cancels an outstanding borrower order
    /// @param id Identifier of the borrower order to cancel
    function cancelBorrow(uint64 id) external {
        Order storage order = borrow_orders[id];
        if (order.owner != msg.sender) revert NotOwner();
        if (order.remaining == 0) revert NoRemaining();

        uint256 bucketId = uint256(order.rateBps) / INCREMENT;
        Bucket storage bucket = borrow_buckets[bucketId];

        uint64 prevId = order.prev;
        uint64 nextId = order.next;

        if (prevId == 0) {
            bucket.head = nextId;
        } else {
            borrow_orders[prevId].next = nextId;
        }
        if (nextId != 0) {
            borrow_orders[nextId].prev = prevId;
        }
        if (bucket.tail == id) {
            bucket.tail = prevId;
        }
        bucket.count--;
        if (bucket.count == 0) {
            _clearBit(borrow_bitmap, bucketId);
        }

        delete borrow_orders[id];

        emit CanceledBorrow(id);
    }

    /// @notice Repays an active loan, transferring principal plus accrued interest to the contract
    /// @param loanId Identifier of the loan to repay
    function repay(uint64 loanId) external {
        Loan storage loan = loans[loanId];

        if (!loan.active) revert LoanNotActive();
        if (loan.borrower != msg.sender) revert NotBorrower();

        uint256 debt = calculateDebt(loanId);
        token.transferFrom(msg.sender, address(this), debt);
        loan.active = false;

        emit Repaid(loanId, debt);
    }

    /// @notice Computes the current repayment amount owed for a loan based on elapsed time
    /// @param loanId Identifier of the loan whose debt is being calculated
    /// @return debt Total amount owed (principal plus accrued interest)
    function calculateDebt(uint64 loanId) public view returns (uint256) {
        Loan memory loan = loans[loanId];
        if (!loan.active) return 0;

        uint256 timeElapsed = block.timestamp - uint256(loan.startTime);
        uint256 interest = (uint256(loan.principal) * uint256(loan.rateBps) * timeElapsed) / (10000 * SECONDS_PER_YEAR);

        return uint256(loan.principal) + interest;
    }

    function getLenderOrder(uint64 id) public view returns (Order memory) {
        return lender_orders[id];
    }

    function getBorrowerOrder(uint64 id) public view returns (Order memory) {
        return borrow_orders[id];
    }

    function getLoan(uint64 id) public view returns (Loan memory) {
        return loans[id];
    }

    function getLenderBucket(uint256 id) public view returns (Bucket memory) {
        return lender_buckets[id];
    }

    function getBorrowerBucket(uint256 id) public view returns (Bucket memory) {
        return borrow_buckets[id];
    }

    /******************************************************************************************************************/
    /*** Internal functions                                                                                         ***/
    /******************************************************************************************************************/

    /// @dev Sets a specific bit within a storage bitmap
    /// @param bitmap Storage array of bitmap words
    /// @param bit Global bit index to set
    function _setBit(uint256[WORDS] storage bitmap, uint256 bit) internal {
        uint256 word  = bit / BITS_PER_WORD;
        uint256 pos   = bit % BITS_PER_WORD;
        bitmap[word] |= (uint256(1) << pos);
    }

    /// @dev Clears a specific bit within a storage bitmap
    /// @param bitmap Storage array of bitmap words
    /// @param bit Global bit index to clear
    function _clearBit(uint256[WORDS] storage bitmap, uint256 bit) internal {
        uint256 word  = bit / BITS_PER_WORD;
        uint256 pos   = bit % BITS_PER_WORD;
        bitmap[word] &= ~(uint256(1) << pos);
    }

    /// @dev Finds the lowest active bucket by scanning the bitmap from lowest index
    /// @param bitmap Storage array of bitmap words
    /// @return index Lowest set bit index, or max uint256 when no bits are set
    function _findLowestSetBit(uint256[WORDS] storage bitmap) internal view returns (uint256) {
        for (uint256 w = 0; w < WORDS; w++) {
            uint256 bits = bitmap[w];
            if (bits != 0) {
                uint256 pos = _ctz(bits);
                return w * BITS_PER_WORD + pos;
            }
        }
        return type(uint256).max;
    }

    /// @dev Finds the highest active bucket by scanning the bitmap from highest index
    /// @param bitmap Storage array of bitmap words
    /// @return index Highest set bit index, or max uint256 when no bits are set
    function _findHighestSetBit(uint256[WORDS] storage bitmap) internal view returns (uint256) {
        for (uint256 w = WORDS; w > 0; ) {
            unchecked { w--; }
            uint256 bits = bitmap[w];
            if (bits != 0) {
                uint256 pos = BITS_PER_WORD - 1 - _clz(bits);
                return w * BITS_PER_WORD + pos;
            }
        }
        return type(uint256).max;
    }

    /// @dev Counts trailing zeros in a uint256 word
    /// @param x Value to inspect
    /// @return n Number of trailing zero bits (256 when x is zero)
    function _ctz(uint256 x) internal pure returns (uint256 n) {
        if (x == 0) return 256;
        n = 0;
        if (x & type(uint128).max == 0) { n += 128; x >>= 128; }
        if (x & type(uint64).max == 0) { n += 64; x >>= 64; }
        if (x & type(uint32).max == 0) { n += 32; x >>= 32; }
        if (x & type(uint16).max == 0) { n += 16; x >>= 16; }
        if (x & type(uint8).max == 0) { n += 8; x >>= 8; }
        if (x & 0xf == 0) { n += 4; x >>= 4; }
        if (x & 0x3 == 0) { n += 2; x >>= 2; }
        if (x & 0x1 == 0) { n += 1; }
    }

    /// @dev Counts leading zeros in a uint256 word
    /// @param x Value to inspect
    /// @return n Number of leading zero bits (256 when x is zero)
    function _clz(uint256 x) internal pure returns (uint256 n) {
        if (x == 0) return 256;
        n = 0;
        if (x >> 128 == 0) { n += 128; x <<= 128; }
        if (x >> 192 == 0) { n += 64; x <<= 64; }
        if (x >> 224 == 0) { n += 32; x <<= 32; }
        if (x >> 240 == 0) { n += 16; x <<= 16; }
        if (x >> 248 == 0) { n += 8; x <<= 8; }
        if (x >> 252 == 0) { n += 4; x <<= 4; }
        if (x >> 254 == 0) { n += 2; x <<= 2; }
        if (x >> 255 == 0) { n += 1; }
    }

    /// @dev Returns the smaller of two unsigned 128-bit integers
    /// @param a First value
    /// @param b Second value
    /// @return Minimum of `a` and `b`
    function _min(uint128 a, uint128 b) internal pure returns (uint128) {
        return a < b ? a : b;
    }

}
