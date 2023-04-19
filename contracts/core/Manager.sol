// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Raffles manager
/// @notice It consumes VRF v1 from Chainlink. It has the role
/// "operator" that is the one used by a backend app to make some calls
/// @dev It saves in an ordered array the player wallet and the current
/// entries count. So buying entries has a complexity of O(1)
/// For calculating the winner, from the huge random number generated by Chainlink
/// a normalized random is generated by using the module method, adding 1 to have
/// a random from 1 to entriesCount.
/// So next step is to perform a binary search on the ordered array to get the
/// player O(log n)
/// Example:
/// 0 -> { 1, player1} as player1 buys 1 entry
/// 1 -> {51, player2} as player2 buys 50 entries
/// 2 -> {52, player3} as player3 buys 1 entry
/// 3 -> {53, player4} as player4 buys 1 entry
/// 4 -> {153, player5} as player5 buys 100 entries
/// So the setWinner method performs a binary search on that sorted array to get the upper bound.
/// If the random number generated is 150, the winner is player5. If the random number is 20, winner is player2

contract Manager is AccessControl, ReentrancyGuard, VRFConsumerBase {
  using SafeERC20 for IERC20;

  ////////// CHAINLINK VRF v1 /////////////////
  bytes32 internal keyHash; // chainlink
  uint256 internal fee; // fee paid in LINK to chainlink. 0.1 in Rinkeby, 2 in mainnet

  struct RandomResult {
    uint256 randomNumber; // random number generated by chainlink.
    uint256 nomalizedRandomNumber; // random number % entriesLength + 1. So between 1 and entries.length
  }

  // event sent when the random number is generated by the VRF
  event RandomNumberCreated(
    bytes32 indexed id,
    uint256 randomNumber,
    uint256 normalizedRandomNumber
  );

  struct RaffleInfo {
    bytes32 id; // raffleId
    uint256 size; // length of the entries array of that raffle
  }

  mapping(bytes32 => RandomResult) public requests;
  // map the requestId created by chainlink with the raffle info passed as param when calling getRandomNumber()
  mapping(bytes32 => RaffleInfo) public chainlinkRaffleInfo;

  /////////////// END CHAINKINK VRF V1 //////////////

  // Event sent when the raffle is created by the operator
  event RaffleCreated(
    bytes32 indexed raffleId,
    address indexed collateralAddress,
    uint256 indexed collateralParam,
    RAFFLETYPE raffleType
  );

  event PriceStructureCreated(
    bytes32 indexed raffleId,
    uint256 indexed structureId,
    uint256 numEntries,
    uint256 price
  );

  // Event sent when the owner of the nft stakes it for the raffle
  event RaffleStarted(bytes32 indexed raffleId, address indexed seller);
  // Event sent when the raffle is finished (either early cashout or successful completion)
  event RaffleEnded(
    bytes32 indexed raffleId,
    address indexed winner,
    uint256 amountRaised,
    uint256 randomNumber
  );
  // Event sent when one or more entries are sold (info from the price structure)
  event EntrySold(
    bytes32 indexed raffleId,
    address indexed buyer,
    uint256 currentSize,
    uint256 priceStructureId
  );
  // Event sent when a free entry is added by the operator
  event FreeEntry(bytes32 indexed raffleId, address[] buyer, uint256 amount, uint256 currentSize);
  // Event sent when a raffle is asked to cancel by the operator
  event RaffleCancelled(bytes32 indexed raffleId, uint256 amountRaised);
  // The raffle is closed successfully and the platform receives the fee
  event FeeTransferredToPlatform(bytes32 indexed raffleId, uint256 amountTransferred);
  // When the raffle is asked to be cancelled and 30 days have passed, the operator can call a method
  // to transfer the remaining funds and this event is emitted
  event RemainingFundsTransferred(bytes32 indexed raffleId, uint256 amountInWeis);
  // When the raffle is asked to be cancelled and 30 days have not passed yet, the players can call a
  // method to refund the amount spent on the raffle and this event is emitted
  event Refund(bytes32 indexed raffleId, uint256 amountInWeis, address indexed player);
  event EarlyCashoutTriggered(bytes32 indexed raffleId, uint256 amountRaised);
  event SetWinnerTriggered(bytes32 indexed raffleId, uint256 amountRaised);
  event StatusChangedInEmergency(bytes32 indexed raffleId, uint256 newStatus);

  /* every raffle has an array of price structure (max size = 5) with the different 
    prices for the different entries bought. The price for 1 entry is different than 
    for 5 entries where there is a discount*/
  struct PriceStructure {
    uint256 id;
    uint256 numEntries;
    uint256 price;
  }
  mapping(bytes32 => PriceStructure[5]) public prices;

  // Every raffle has a funding structure.
  struct FundingStructure {
    uint256 minimumFundsInWeis;
    uint256 desiredFundsInWeis;
  }
  mapping(bytes32 => FundingStructure) public fundingList;

  // In order to calculate the winner, in this struct is saved for each bought the data
  struct EntriesBought {
    uint256 currentEntriesLength; // current amount of entries bought in the raffle
    address player; // wallet address of the player
  }
  // every raffle has a sorted array of EntriesBought. Each element is created when calling
  // either buyEntry or giveBatchEntriesForFree
  mapping(bytes32 => uint256) public entriesCount;
  mapping(bytes32 => mapping(uint256 => EntriesBought)) public entries;

  // Raffle create struct
  struct RaffleCreateParam {
    RAFFLETYPE raffleType; // type of raffle
    uint256 desiredFundsInWeis; // the amount the seller would like to get from the raffle
    uint256 maxEntriesPerUser; // To avoid whales, the number of entries an user can have is limited
    address collateralAddress; // The address of the NFT of the raffle
    uint256 collateralParam; // The id of the NFT (ERC721)
    uint256 minimumFundsInWeis; // The mininum amount required for the raffle to set a winner
    uint256 commissionInBasicPoints; // commission for the platform, in basic points
  }

  // Main raffle data struct
  struct RaffleStruct {
    RAFFLETYPE raffleType; // type of raffle
    STATUS status; // status of the raffle. Can be created, accepted, ended, etc
    uint256 maxEntries; // maximum number of entries allowed per user, to avoid abuse
    address collateralAddress; // address of the NFT
    uint256 collateralParam; // NFT id of the NFT, amount of reward token
    address winner; // address of thed winner of the raffle. Address(0) if no winner yet
    uint256 randomNumber; // normalized (0-Entries array size) random number generated by the VRF
    uint256 amountRaised; // funds raised so far in wei
    address seller; // address of the seller of the NFT
    uint256 platformPercentage; // percentage of the funds raised that goes to the platform
    uint256 cancellingDate;
    address[] collectionWhitelist; // addresses of the required nfts. Will be empty if no NFT is required to buy
  }
  // The main structure is an array of raffles
  mapping(bytes32 => RaffleStruct) public raffles;

  // Map that contains the number of entries each user has bought, to prevent abuse, and the claiming info
  struct ClaimStruct {
    uint256 numEntriesPerUser;
    uint256 amountSpentInWeis;
    bool claimed;
  }
  mapping(bytes32 => ClaimStruct) public claimsData;

  // Map with the addresses linked to a particular raffle + nft
  mapping(bytes32 => address) public requiredNFTWallets;

  // Type of Raffle
  enum RAFFLETYPE {
    NFT, // NFT raffle
    ETH, // Native token raffle
    ERC20 // erc20 token raffle
  }
  // All the different status a rafVRFCoordinatorfle can have
  enum STATUS {
    CREATED, // the operator creates the raffle
    ACCEPTED, // the seller stakes the nft for the raffle
    EARLY_CASHOUT, // the seller wants to cashout early
    CANCELLED, // the operator cancels the raffle and transfer the remaining funds after 30 days passes
    CLOSING_REQUESTED, // the operator sets a winner
    ENDED, // the raffle is finished, and NFT and funds were transferred
    CANCEL_REQUESTED // operator asks to cancel the raffle. Players has 30 days to ask for a refund
  }

  // The operator role is operated by a backend application
  bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

  // address of the wallet controlled by the platform that will receive the platform fee
  address payable public destinationWallet = payable(0xEda703919A528481F4F11423a728300dCaBF441F);

  constructor(
    address _vrfCoordinator,
    address _linkToken,
    bytes32 _keyHash,
    uint256 _fee
  )
    VRFConsumerBase(
      _vrfCoordinator, // VRF Coordinator
      _linkToken // LINK Token
    )
  {
    _setupRole(OPERATOR_ROLE, 0x13503B622abC0bD30A7e9687057DF6E8c42Fb928);
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);

    keyHash = _keyHash;
    fee = _fee;
  }

  /// @dev this is the method that will be called by the smart contract to get a random number
  /// @param _id Id of the raffle
  /// @param _entriesSize length of the entries array of that raffle
  /// @return requestId Id generated by chainlink
  function getRandomNumber(bytes32 _id, uint256 _entriesSize) internal returns (bytes32 requestId) {
    require(LINK.balanceOf(address(this)) > fee, "Not enough LINK - fill contract with faucet");
    bytes32 result = requestRandomness(keyHash, fee);
    // result is the requestId generated by chainlink. It is saved in a map linked to the param id
    chainlinkRaffleInfo[result] = RaffleInfo({id: _id, size: _entriesSize});
    return result;
  }

  /// @dev Callback function used by VRF Coordinator. Is called by chainlink
  /// the random number generated is normalized to the size of the entries array, and an event is
  /// generated, that will be listened by the platform backend to be checked if corresponds to a
  /// member of the MW community, and if true will call transferNFTAndFunds
  /// @param requestId id generated previously (on method getRandomNumber by chainlink)
  /// @param randomness random number (huge) generated by chainlink
  function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override {
    // randomness is the actual random number. Now extract from the aux map the original param id of the call
    RaffleInfo memory raffleInfo = chainlinkRaffleInfo[requestId];
    // save the random number on the map with the original id as key
    uint256 normalizedRandomNumber = (randomness % raffleInfo.size) + 1;

    RandomResult memory result = RandomResult({
      randomNumber: randomness,
      nomalizedRandomNumber: normalizedRandomNumber
    });

    requests[raffleInfo.id] = result;

    // send the event with the original id and the random number
    emit RandomNumberCreated(raffleInfo.id, randomness, normalizedRandomNumber);

    transferNFTAndFunds(raffleInfo.id, normalizedRandomNumber);
  }

  //////////////////////////////////////////////

  /// @param raffle raffle structure to get key
  /// @notice get raffle kay for mapping
  /// @dev use hash of structure as a key
  /// @return bytes32 return key
  function getRaffleKey(RaffleStruct memory raffle) internal view returns (bytes32) {
    return
      keccak256(
        abi.encodePacked(
          raffle.raffleType,
          raffle.collateralAddress,
          raffle.collateralParam,
          block.number
        )
      );
  }

  /// @param _params params to create raffle
  /// @param _prices Array of prices and amount of entries the customer could purchase
  /// @param _collectionWhitelist array with the required collections to participate in the raffle. Empty if there is no collection
  /// @notice Creates a raffle with NFT
  /// @dev creates a raffle struct and push it to the raffles array. Some data is stored in the funding data structure
  /// sends an event when finished
  /// @return raffleId
  function createRaffle(
    RaffleCreateParam calldata _params,
    PriceStructure[] calldata _prices,
    address[] calldata _collectionWhitelist
  ) external onlyRole(OPERATOR_ROLE) returns (bytes32) {
    require(_params.maxEntriesPerUser > 0, "maxEntries is 0");
    require(_params.commissionInBasicPoints <= 5000, "commission too high");

    RaffleStruct memory raffle = RaffleStruct({
      raffleType: _params.raffleType,
      status: STATUS.CREATED,
      maxEntries: _params.maxEntriesPerUser,
      collateralAddress: _params.collateralAddress,
      collateralParam: _params.collateralParam,
      winner: address(0),
      randomNumber: 0,
      amountRaised: 0,
      seller: address(0),
      platformPercentage: _params.commissionInBasicPoints,
      cancellingDate: 0,
      collectionWhitelist: _collectionWhitelist
    });

    bytes32 key = getRaffleKey(raffle);
    raffles[key] = raffle;

    require(_prices.length > 0, "No prices");

    for (uint256 i = 0; i < _prices.length; i++) {
      require(_prices[i].numEntries > 0, "numEntries is 0");

      prices[key][i] = _prices[i];

      emit PriceStructureCreated(key, _prices[i].id, _prices[i].numEntries, _prices[i].price);
    }

    fundingList[key] = FundingStructure({
      minimumFundsInWeis: _params.minimumFundsInWeis,
      desiredFundsInWeis: _params.desiredFundsInWeis
    });

    emit RaffleCreated(key, _params.collateralAddress, _params.collateralParam, _params.raffleType);

    return key;
  }

  /* * Example of a price structure:
    1 ticket 0.02
    5 tickets 0.018 (10% discount)
    10 tickets 0.16  (20% discount)
    25 tickets 0.35  (30% discount) 
    50 tickets 0.6 (40% discount)
    */
  /// @param _idRaffle raffleId
  /// @param _id Id of the price structure
  /// @return the price structure of that particular Id + raffle
  /// @dev Returns the price structure, used in the frontend
  function getPriceStructForId(
    bytes32 _idRaffle,
    uint256 _id
  ) internal view returns (PriceStructure memory) {
    for (uint256 i = 0; i < 5; i++) {
      if (prices[_idRaffle][i].id == _id) {
        return prices[_idRaffle][i];
      }
    }
    return PriceStructure({id: 0, numEntries: 0, price: 0});
  }

  /*
    Callable only by the owner of the NFT
    Once the operator has created the raffle, he can stake the NFT
    At this moment, the NFT is locked and the players can buy entries
    */
  /// @param _raffleId Id of the raffle
  /// @notice The owner of the NFT can stake it on the raffle. At this moment the raffle starts and can sell entries to players
  /// @dev the owner must have approved this contract before. Otherwise will revert when transferring from the owner
  function stakeNFT(bytes32 _raffleId) external {
    RaffleStruct memory raffle = raffles[_raffleId];
    // Check if the raffle is already created
    require(raffle.raffleType == RAFFLETYPE.NFT, "Invalid raffle type");
    require(raffle.collateralAddress != address(0), "Invalid nft address");
    require(raffle.status == STATUS.CREATED, "Raffle not CREATED");
    // the owner of the NFT must be the current caller
    IERC721 token = IERC721(raffle.collateralAddress);
    require(token.ownerOf(raffle.collateralParam) == msg.sender, "NFT is not owned by caller");

    raffle.status = STATUS.ACCEPTED;
    raffle.seller = msg.sender;

    raffles[_raffleId] = raffle;
    // transfer the asset to the contract
    //  IERC721 _asset = IERC721(raffle.collateralAddress);
    token.transferFrom(msg.sender, address(this), raffle.collateralParam); // transfer the token to the contract

    emit RaffleStarted(_raffleId, msg.sender);
  }

  /// @param _raffleId Id of the raffle
  /// @notice The owner of the ERC20 can stake it on the raffle. At this moment the raffle starts and can sell entries to players
  /// @dev the owner must have approved this contract before. Otherwise will revert when transferring from the owner
  function stakeERC20(bytes32 _raffleId) external {
    RaffleStruct memory raffle = raffles[_raffleId];
    // Check if the raffle is already created
    require(raffle.raffleType == RAFFLETYPE.ERC20, "Invalid raffle type");
    require(raffle.collateralAddress != address(0), "Invalid token address");
    require(raffle.status == STATUS.CREATED, "Raffle not CREATED");

    IERC20 token = IERC20(raffle.collateralAddress);

    raffle.status = STATUS.ACCEPTED;
    raffle.seller = msg.sender;

    raffles[_raffleId] = raffle;

    // transfer the asset to the contract
    //  IERC20 _asset = IERC20(raffle.collateralAddress);
    token.safeTransferFrom(msg.sender, address(this), raffle.collateralParam); // transfer the token to the contract

    emit RaffleStarted(_raffleId, msg.sender);
  }

  /// @param _raffleId Id of the raffle
  /// @notice The owner of the ETH can stake it on the raffle. At this moment the raffle starts and can sell entries to players
  /// @dev the owner must have approved this contract before. Otherwise will revert when transferring from the owner
  function stakeETH(bytes32 _raffleId) external payable {
    RaffleStruct memory raffle = raffles[_raffleId];
    // Check if the raffle is already created
    require(raffle.raffleType == RAFFLETYPE.ETH, "Invalid raffle type");
    require(raffle.status == STATUS.CREATED, "Raffle not CREATED");
    require(msg.value == raffle.collateralParam, "Invalid deposit amount");

    raffle.status = STATUS.ACCEPTED;
    raffle.seller = msg.sender;

    raffles[_raffleId] = raffle;

    emit RaffleStarted(_raffleId, msg.sender);
  }

  /// @dev callable by players. Depending on the number of entries assigned to the price structure the player buys (_id parameter)
  /// one or more entries will be assigned to the player.
  /// Also it is checked the maximum number of entries per user is not reached
  /// As the method is payable, in msg.value there will be the amount paid by the user
  /// @notice If the operator set requiredNFTs when creating the raffle, only the owners of nft on that collection can make a call to this method. This will be
  /// used for special raffles
  /// @param _raffleId: id of the raffle
  /// @param _id: id of the price structure
  /// @param _collection: collection of the tokenId used. Not used if there is no required nft on the raffle
  /// @param _tokenIdUsed: id of the token used in private raffles (to avoid abuse can not be reused on the same raffle)
  function buyEntry(
    bytes32 _raffleId,
    uint256 _id,
    address _collection,
    uint256 _tokenIdUsed
  ) external payable nonReentrant {
    // if the raffle requires an nft
    if (raffles[_raffleId].collectionWhitelist.length > 0) {
      bool hasRequiredCollection = false;
      for (uint256 i = 0; i < raffles[_raffleId].collectionWhitelist.length; i++) {
        if (raffles[_raffleId].collectionWhitelist[i] == _collection) {
          hasRequiredCollection = true;
          break;
        }
      }
      require(hasRequiredCollection == true, "Not in required collection");
      IERC721 requiredNFT = IERC721(_collection);
      require(requiredNFT.ownerOf(_tokenIdUsed) == msg.sender, "Not the owner of tokenId");
      bytes32 hashRequiredNFT = keccak256(abi.encode(_collection, _raffleId, _tokenIdUsed));
      // check the tokenId has not been using yet in the raffle, to avoid abuse
      if (requiredNFTWallets[hashRequiredNFT] == address(0)) {
        requiredNFTWallets[hashRequiredNFT] = msg.sender;
      } else require(requiredNFTWallets[hashRequiredNFT] == msg.sender, "tokenId used");
    }

    require(msg.sender != address(0), "msg.sender is null"); // 37
    require(_id > 0, "howMany is 0");
    require(raffles[_raffleId].status == STATUS.ACCEPTED, "Raffle is not in accepted"); // 1808
    PriceStructure memory priceStruct = getPriceStructForId(_raffleId, _id);
    require(priceStruct.numEntries > 0, "id not supported");
    require(msg.value == priceStruct.price, "msg.value must be equal to the price"); // 1722

    bytes32 hash = keccak256(abi.encode(msg.sender, _raffleId));
    // check there are enough entries left for this particular user
    require(
      claimsData[hash].numEntriesPerUser + priceStruct.numEntries <= raffles[_raffleId].maxEntries,
      "Bought too many entries"
    );

    // add a new element to the entriesBought array, used to calc the winner
    EntriesBought memory entryBought = EntriesBought({
      player: msg.sender,
      currentEntriesLength: entriesCount[_raffleId]
    });
    entries[_raffleId][entriesCount[_raffleId]] = entryBought;
    entriesCount[_raffleId]++;

    raffles[_raffleId].amountRaised += msg.value; // 6917 gas
    //update claim data
    claimsData[hash].numEntriesPerUser += priceStruct.numEntries;
    claimsData[hash].amountSpentInWeis += msg.value;

    emit EntrySold(_raffleId, msg.sender, entriesCount[_raffleId] - 1, _id); // 2377
  }

  // The operator can add free entries to the raffle
  /// @param _raffleId Id of the raffle
  /// @param _freePlayers array of addresses corresponding to the wallet of the users that won a free entrie
  /// @dev only operator can make this call. Assigns a single entry per user, except if that user already reached the max limit of entries per user
  function giveBatchEntriesForFree(
    bytes32 _raffleId,
    address[] memory _freePlayers
  ) external nonReentrant onlyRole(OPERATOR_ROLE) {
    require(raffles[_raffleId].status == STATUS.ACCEPTED, "Raffle is not in accepted");

    uint256 freePlayersLength = _freePlayers.length;
    for (uint256 i = 0; i < freePlayersLength; i++) {
      address entry = _freePlayers[i];
      if (
        claimsData[keccak256(abi.encode(entry, _raffleId))].numEntriesPerUser + 1 <=
        raffles[_raffleId].maxEntries
      ) {
        // add a new element to the entriesBought array.
        // as this method only adds 1 entry per call, the amountbought is always 1
        EntriesBought memory entryBought = EntriesBought({
          player: entry,
          currentEntriesLength: entriesCount[_raffleId]
        });
        entries[_raffleId][entriesCount[_raffleId]] = entryBought;
        entriesCount[_raffleId]++;

        claimsData[keccak256(abi.encode(entry, _raffleId))].numEntriesPerUser++;
      }
    }

    emit FreeEntry(_raffleId, _freePlayers, freePlayersLength, entriesCount[_raffleId] - 1);
  }

  // helper method to get the winner address of a raffle
  /// @param _raffleId Id of the raffle
  /// @param _normalizedRandomNumber Generated by chainlink
  /// @return the wallet that won the raffle
  /// @dev Uses a binary search on the sorted array to retreive the winner
  function getWinnerAddressFromRandom(
    bytes32 _raffleId,
    uint256 _normalizedRandomNumber
  ) public view returns (address) {
    uint256 position = findUpperBound(_raffleId, _normalizedRandomNumber);
    return entries[_raffleId][position].player;
  }

  /// @param id id of raffle
  /// @param element uint256 to find. Goes from 1 to entriesLength
  /// @dev based on openzeppelin code (v4.0), modified to use an array of EntriesBought
  /// Searches a sorted array and returns the first index that contains a value greater or equal to element.
  /// If no such index exists (i.e. all values in the array are strictly less than element), the array length is returned. Time complexity O(log n).
  /// array is expected to be sorted in ascending order, and to contain no repeated elements.
  /// https://docs.openzeppelin.com/contracts/3.x/api/utils#Arrays-findUpperBound-uint256---uint256-
  function findUpperBound(bytes32 id, uint256 element) internal view returns (uint256) {
    if (entriesCount[id] == 0) {
      return 0;
    }

    uint256 low = 0;
    uint256 high = entriesCount[id];

    while (low < high) {
      uint256 mid = Math.average(low, high);

      // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
      // because Math.average rounds down (it does integer division with truncation).
      if (entries[id][mid].currentEntriesLength > element) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }

    // At this point `low` is the exclusive upper bound. We will return the inclusive upper bound.
    if (low > 0 && entries[id][low - 1].currentEntriesLength == element) {
      return low - 1;
    } else {
      return low;
    }
  }

  // The operator can call this method once they receive the event "RandomNumberCreated"
  // triggered by the VRF v1 consumer contract (RandomNumber.sol)
  /// @param _raffleId Id of the raffle
  /// @param _normalizedRandomNumber index of the array that contains the winner of the raffle. Generated by chainlink
  /// @notice it is the method that sets the winner and transfers funds and nft
  /// @dev called only after the backekd checks the winner is a member of MW. Only those who bought using the MW site
  /// can be winners, not those who made the call to "buyEntries" directly without using MW
  function transferNFTAndFunds(
    bytes32 _raffleId,
    uint256 _normalizedRandomNumber
  ) internal nonReentrant {
    RaffleStruct memory raffle = raffles[_raffleId];
    // Only when the raffle has been asked to be closed and the platform
    require(
      raffle.status == STATUS.EARLY_CASHOUT || raffle.status == STATUS.CLOSING_REQUESTED,
      "Raffle in wrong status"
    );

    raffle.randomNumber = _normalizedRandomNumber;
    raffle.winner = getWinnerAddressFromRandom(_raffleId, _normalizedRandomNumber);
    raffle.status = STATUS.ENDED;

    if (raffle.raffleType == RAFFLETYPE.NFT) {
      IERC721 _asset = IERC721(raffle.collateralAddress);
      _asset.transferFrom(address(this), raffle.winner, raffle.collateralParam); // transfer the tokens to the contract
    } else if (raffle.raffleType == RAFFLETYPE.ERC20) {
      IERC20 _asset = IERC20(raffle.collateralAddress);
      _asset.safeTransfer(raffle.winner, raffle.collateralParam); // transfer the tokens to the contract
    } else {
      (bool sent, ) = raffle.winner.call{value: raffle.collateralParam}("");
      require(sent, "Failed to send Ether");
    }

    uint256 amountForPlatform = (raffle.amountRaised * raffle.platformPercentage) / 10000;
    uint256 amountForSeller = raffle.amountRaised - amountForPlatform;
    // transfer amount (75%) to the seller.
    (bool sent1, ) = raffle.seller.call{value: amountForSeller}("");
    require(sent1, "Failed to send Ether");
    // transfer the amount to the platform
    (bool sent2, ) = destinationWallet.call{value: amountForPlatform}("");
    require(sent2, "Failed send Eth to MW");
    emit FeeTransferredToPlatform(_raffleId, amountForPlatform);

    emit RaffleEnded(_raffleId, raffle.winner, raffle.amountRaised, _normalizedRandomNumber);
  }

  // can be called by the seller at every moment once enough funds has been raised
  /// @param _raffleId Id of the raffle
  /// @notice the seller of the nft, if the minimum amount has been reached, can call an early cashout, finishing the raffle
  /// @dev it triggers Chainlink VRF1 consumer, and generates a random number that is normalized and checked that corresponds to a MW player
  function earlyCashOut(bytes32 _raffleId) external {
    RaffleStruct storage raffle = raffles[_raffleId];
    FundingStructure memory funding = fundingList[_raffleId];

    require(raffle.seller == msg.sender, "Not the seller");
    // Check if the raffle is already accepted
    require(raffle.status == STATUS.ACCEPTED, "Raffle not in accepted status");
    require(raffle.amountRaised >= funding.minimumFundsInWeis, "Not enough funds raised");

    raffle.status = STATUS.EARLY_CASHOUT;

    //    IVRFConsumerv1 randomNumber = IVRFConsumerv1(chainlinkContractAddress);
    getRandomNumber(_raffleId, entriesCount[_raffleId]);

    emit EarlyCashoutTriggered(_raffleId, raffle.amountRaised);
  }

  /// @param _raffleId Id of the raffle
  /// @notice the operator finish the raffle, if the desired funds has been reached
  /// @dev it triggers Chainlink VRF1 consumer, and generates a random number that is normalized and checked that corresponds to a MW player
  function setWinner(bytes32 _raffleId) external nonReentrant onlyRole(OPERATOR_ROLE) {
    RaffleStruct storage raffle = raffles[_raffleId];
    FundingStructure storage funding = fundingList[_raffleId];
    // Check if the raffle is already accepted or is called again because early cashout failed
    require(raffle.status == STATUS.ACCEPTED, "Raffle in wrong status");
    require(raffle.amountRaised >= funding.minimumFundsInWeis, "Not enough funds raised");

    require(funding.desiredFundsInWeis <= raffle.amountRaised, "Desired funds not raised");
    raffle.status = STATUS.CLOSING_REQUESTED;

    // this call trigers the VRF v1 process from Chainlink
    getRandomNumber(_raffleId, entriesCount[_raffleId]);

    emit SetWinnerTriggered(_raffleId, raffle.amountRaised);
  }

  /// @param _newAddress new address of the platform
  /// @dev Change the wallet of the platform. The one that will receive the platform fee when the raffle is closed.
  /// Only the admin can change this
  function setDestinationAddress(
    address payable _newAddress
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    destinationWallet = _newAddress;
  }

  /// @param _raffleId Id of the raffle
  /// @dev The operator can cancel the raffle. The NFT is sent back to the seller
  /// The raised funds are send to the destination wallet. The buyers will
  /// be refunded offchain in the metawin wallet
  function cancelRaffle(bytes32 _raffleId) external nonReentrant onlyRole(OPERATOR_ROLE) {
    RaffleStruct storage raffle = raffles[_raffleId];
    //FundingStructure memory funding = fundingList[_raffleId];
    // Dont cancel twice, or cancel an already ended raffle
    require(
      raffle.status != STATUS.ENDED &&
        raffle.status != STATUS.CANCELLED &&
        raffle.status != STATUS.EARLY_CASHOUT &&
        raffle.status != STATUS.CLOSING_REQUESTED &&
        raffle.status != STATUS.CANCEL_REQUESTED,
      "Wrong status"
    );

    // only if the raffle is in accepted status the NFT is staked and could have entries sold
    if (raffle.status == STATUS.ACCEPTED) {
      // transfer nft to the owner
      IERC721 _asset = IERC721(raffle.collateralAddress);
      _asset.transferFrom(address(this), raffle.seller, raffle.collateralParam);
    }
    raffle.status = STATUS.CANCEL_REQUESTED;
    raffle.cancellingDate = block.timestamp;

    emit RaffleCancelled(_raffleId, raffle.amountRaised);
  }

  /// @param _raffleId Id of the raffle
  /// @dev The player can claim a refund during the first 30 days after the raffle was cancelled
  /// in the map "ClaimsData" it is saves how much the player spent on that raffle, as they could
  /// have bought several entries
  function claimRefund(bytes32 _raffleId) external nonReentrant {
    RaffleStruct storage raffle = raffles[_raffleId];
    require(raffle.status == STATUS.CANCEL_REQUESTED, "wrong status");
    require(block.timestamp <= raffle.cancellingDate + 30 days, "claim time expired");

    ClaimStruct storage claimData = claimsData[keccak256(abi.encode(msg.sender, _raffleId))];

    require(claimData.claimed == false, "already refunded");

    raffle.amountRaised = raffle.amountRaised - claimData.amountSpentInWeis;

    claimData.claimed = true;
    (bool sent, ) = msg.sender.call{value: claimData.amountSpentInWeis}("");
    require(sent, "Fail send refund");

    emit Refund(_raffleId, claimData.amountSpentInWeis, msg.sender);
  }

  /// @param _raffleId Id of the raffle
  /// @dev after 30 days after cancelling passes, the operator can transfer to
  /// destinationWallet the remaining funds
  function transferRemainingFunds(bytes32 _raffleId) external nonReentrant onlyRole(OPERATOR_ROLE) {
    RaffleStruct storage raffle = raffles[_raffleId];
    require(raffle.status == STATUS.CANCEL_REQUESTED, "Wrong status");
    require(block.timestamp > raffle.cancellingDate + 30 days, "claim too soon");

    raffle.status = STATUS.CANCELLED;

    (bool sent, ) = destinationWallet.call{value: raffle.amountRaised}("");
    require(sent, "Fail send Eth to MW");

    emit RemainingFundsTransferred(_raffleId, raffle.amountRaised);

    raffle.amountRaised = 0;
  }

  /// @param _raffleId Id of the raffle
  /// @param _player wallet of the player
  /// @return Claims data of the player on that raffle
  function getClaimData(
    bytes32 _raffleId,
    address _player
  ) external view returns (ClaimStruct memory) {
    return claimsData[keccak256(abi.encode(_player, _raffleId))];
  }
}
