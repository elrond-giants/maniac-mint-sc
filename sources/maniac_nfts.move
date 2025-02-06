module maniac_nfts::maniac_nfts;

use kiosk::kiosk_lock_rule;
use kiosk::royalty_rule as kiosk_royalty_rule;
use maniac_nfts::maniac_attribute::{
    ManiacAttributeNft,
    field_type,
    field_value,
    create_random_attribute,
    AttributeMapping
};
use maniac_wl::maniac_wl::WlNft;
use std::string::{Self, String};
use sui::coin::Coin;
use sui::display;
use sui::dynamic_object_field as ofield;
use sui::kiosk::{Self, Kiosk, KioskOwnerCap};
use sui::package;
use sui::random::Random;
use sui::sui::SUI;
use sui::transfer_policy::{Self, TransferPolicy};
use sui::vec_map::{Self, VecMap};

// TODO: Change this before deploy to mainnet
const MAX_SUPPLY: u64 = 100;
const IMAGE_BASE_URL: vector<u8> = b"https://metadata.coinfever.app/api/image/?id=";
const NFT_BASE_NAME: vector<u8> = b"Fever Maniac #";
const WL_PRICE: u64 = 1;
const PUBLIC_PRICE: u64 = 1;
const ONE_SUI: u64 = 1000000000;
const ROYALTIES: u16 = 10_00; // 10%
const MIN_ROYALTIES: u64 = ONE_SUI / 10; // 0.1 SUI

// TODO: Add limit per wallet (see if we can make it more fancy with WLs)

// Errors
const EInvalidQuantity: u64 = 0;
const EMintTooMany: u64 = 1;
const EInvalidPayment: u64 = 2;
const ENotAdmin: u64 = 3;

public struct Admin has store {
    admin_address: address,
}

public struct MintingControl has key, store {
    id: UID,
    paused: bool,
    counter: u64,
    admin: Admin,
    price_wl: u64,
    price_public: u64,
}

public struct MANIAC_NFTS has drop {}

public struct ManiacNft has key, store {
    id: UID,
    name: String,
    image_url: String,
    attributes: VecMap<String, String>,
}

fun is_admin(control: &MintingControl, caller: address): bool {
    control.admin.admin_address == caller
}

/*
Initializes the NFT collection and sets up policies for transfer and kiosk usage.
*/
#[lint_allow(self_transfer, share_owned)]
fun init(otw: MANIAC_NFTS, ctx: &mut TxContext) {
    let keys = vector[
        b"name".to_string(),
        b"image_url".to_string(),
        b"project_url".to_string(),
        b"creator".to_string(),
    ];

    let values = vector[
        b"{name}".to_string(),
        b"{image_url}".to_string(),
        b"https://coinfever.app".to_string(),
        b"CoinFever".to_string(),
    ];

    let publisher = package::claim(otw, ctx);

    let mut display = display::new_with_fields<ManiacNft>(
        &publisher,
        keys,
        values,
        ctx,
    );

    display.update_version();

    let sender = ctx.sender();

    let (mut policy, policy_cap) = transfer_policy::new<ManiacNft>(&publisher, ctx);

    // Kiosk Royalties rule
    kiosk_royalty_rule::add(&mut policy, &policy_cap, ROYALTIES, MIN_ROYALTIES);

    // Kiosk Lock rule
    kiosk_lock_rule::add(&mut policy, &policy_cap);

    let mintingControl = MintingControl {
        id: object::new(ctx),
        admin: Admin { admin_address: sender },
        counter: 0,
        paused: false, // TODO: Change this to true before deploy to mainnet
        price_wl: WL_PRICE * ONE_SUI,
        price_public: PUBLIC_PRICE * ONE_SUI,
    };

    transfer::public_transfer(publisher, sender);
    transfer::public_transfer(display, sender);
    transfer::public_transfer(policy_cap, sender);
    transfer::share_object(mintingControl);
    transfer::public_share_object(policy);
}

/*
Mints an NFT to a specific address with 5 random attribute NFTs. The body and attributes are separate collections. Body NFT is locked inside a kiosk.
*/
fun mint_to_address(
    control: &mut MintingControl,
    attributes_mapping: &AttributeMapping,
    random: &Random,
    kiosk: &mut Kiosk,
    kiosk_cap: &KioskOwnerCap,
    transfer_policy: &TransferPolicy<ManiacNft>,
    sender: address,
    ctx: &mut TxContext,
) {
    let mut fullName = vector::empty();
    fullName.append(NFT_BASE_NAME);
    fullName.append(*control.counter.to_string().as_bytes());

    let nftId = object::new(ctx);

    let mut imageUrl = IMAGE_BASE_URL;
    let objectIdString = nftId.to_address().to_string().as_bytes();
    imageUrl.append(*objectIdString);

    let mut attributes = vec_map::empty<String, String>();
    attributes.insert(string::utf8(b"type"), string::utf8(b"Body"));
    attributes.insert(string::utf8(b"background"), string::utf8(b"None"));
    attributes.insert(string::utf8(b"body"), string::utf8(b"None"));
    attributes.insert(string::utf8(b"hat"), string::utf8(b"None"));
    attributes.insert(string::utf8(b"beard"), string::utf8(b"None"));
    attributes.insert(string::utf8(b"eyes"), string::utf8(b"None"));

    let nft = ManiacNft {
        id: nftId,
        name: string::utf8(fullName),
        image_url: string::utf8(imageUrl),
        attributes,
    };

    control.counter = control.counter + 1;

    kiosk::lock(kiosk, kiosk_cap, transfer_policy, nft);

    let backgroundAttribute = create_random_attribute(
        attributes_mapping,
        b"background",
        random,
        ctx,
    );
    transfer::public_transfer(backgroundAttribute, sender);
    let beardAttribute = create_random_attribute(attributes_mapping, b"beard", random, ctx);
    transfer::public_transfer(beardAttribute, sender);
    let bodyAttribute = create_random_attribute(attributes_mapping, b"body", random, ctx);
    transfer::public_transfer(bodyAttribute, sender);
    let hatAttribute = create_random_attribute(attributes_mapping, b"hat", random, ctx);
    transfer::public_transfer(hatAttribute, sender);
    let eyesAttribute = create_random_attribute(attributes_mapping, b"eyes", random, ctx);
    transfer::public_transfer(eyesAttribute, sender);
}

/*
Public mint function with referral capability. 
*/
entry fun mint(
    control: &mut MintingControl,
    attributes_mapping: &AttributeMapping,
    random: &Random,
    coin: Coin<SUI>,
    quantity: u64,
    kiosk: &mut Kiosk,
    kiosk_cap: &KioskOwnerCap,
    transfer_policy: &TransferPolicy<ManiacNft>,
    ctx: &mut TxContext,
) {
    assert!(quantity > 0 && quantity <= 50, EInvalidQuantity);

    assert!(quantity + control.counter <= MAX_SUPPLY, EMintTooMany);

    assert!(coin.value() == quantity * control.price_public, EInvalidPayment);

    let mut i = 0;

    let sender = ctx.sender();

    while (i < quantity) {
        mint_to_address(
            control,
            attributes_mapping,
            random,
            kiosk,
            kiosk_cap,
            transfer_policy,
            sender,
            ctx,
        );
        i = i + 1;
    };

    // if (referral.is_some()) {
    //     let referralAddress = referral.get_with_default(ctx.sender());
    //     let referralValue = coin.value() * REFERRAL_PERCENT / 100;
    //     let referralCoin = coin::take(coin.balance_mut(), referralValue, ctx);
    //     transfer::public_transfer(referralCoin, referralAddress);
    // };

    // transfer::public_transfer(coin, ctx.sender());
    transfer::public_transfer(coin, control.admin.admin_address);
}

/*
Whitelist mint function.
*/
entry fun mint_wl(
    control: &mut MintingControl,
    attributes_mapping: &AttributeMapping,
    random: &Random,
    _wl: &mut WlNft,
    coin: Coin<SUI>,
    quantity: u64,
    kiosk: &mut Kiosk,
    kiosk_cap: &KioskOwnerCap,
    transfer_policy: &TransferPolicy<ManiacNft>,
    ctx: &mut TxContext,
) {
    assert!(quantity > 0 && quantity <= 50, EInvalidQuantity);

    assert!(quantity + control.counter <= MAX_SUPPLY, EMintTooMany);

    assert!(coin.value() == quantity * control.price_wl, EInvalidPayment);

    let mut i = 0;
    let sender = ctx.sender();

    while (i < quantity) {
        mint_to_address(
            control,
            attributes_mapping,
            random,
            kiosk,
            kiosk_cap,
            transfer_policy,
            sender,
            ctx,
        );
        i = i + 1;
    };

    transfer::public_transfer(coin, control.admin.admin_address);
}

/*
Set or remove attributes from a Fever Maniac NFT. Attributes are stored inside dynamic object fields.
*/
#[allow(lint(self_transfer))]
public fun set_attribute(
    nft_id: ID,
    kiosk: &mut Kiosk,
    cap: &KioskOwnerCap,
    mut add_attributes: vector<ManiacAttributeNft>,
    mut remove_attributes: vector<vector<u8>>,
    ctx: &mut TxContext,
) {
    assert!(add_attributes.length() <= 5, 1);
    assert!(remove_attributes.length() <= 5, 1);
    assert!(add_attributes.length() > 0 || remove_attributes.length() > 0, 1);

    let nft = kiosk::borrow_mut<ManiacNft>(kiosk, cap, nft_id);

    let sender = ctx.sender();

    while (!remove_attributes.is_empty()) {
        let name = remove_attributes.pop_back();

        if (ofield::exists_(&nft.id, name)) {
            let removedAttribute = ofield::remove<vector<u8>, ManiacAttributeNft>(
                &mut nft.id,
                name,
            );
            transfer::public_transfer(removedAttribute, sender);
        };
    };

    while (!add_attributes.is_empty()) {
        let attribute = add_attributes.pop_back();
        let name = field_type(&attribute).as_bytes();
        let value = field_value(&attribute).as_bytes();

        if (ofield::exists_(&nft.id, *name)) {
            let removedAttribute = ofield::remove<vector<u8>, ManiacAttributeNft>(
                &mut nft.id,
                *name,
            );
            transfer::public_transfer(removedAttribute, sender);
        };

        nft.attributes.remove(&string::utf8(*name));
        nft.attributes.insert(string::utf8(*name), string::utf8(*value));

        // if (name == b"background") {
        //     nft.attributes.background = string::utf8(*value);
        // } else if (name == b"body") {
        //     nft.attributes.body = string::utf8(*value);
        // } else if (name == b"hat") {
        //     nft.attributes.hat = string::utf8(*value);
        // } else if (name == b"beard") {
        //     nft.attributes.beard = string::utf8(*value);
        // } else if (name == b"eyes") {
        //     nft.attributes.eyes = string::utf8(*value);
        // };

        ofield::add(&mut nft.id, *name, attribute);
    };

    add_attributes.destroy_empty();
    remove_attributes.destroy_empty();
}

entry fun giveaway(
    control: &mut MintingControl,
    attributes_mapping: &AttributeMapping,
    random: &Random,
    mut address_list: vector<address>,
    transfer_policy: &TransferPolicy<ManiacNft>,
    ctx: &mut TxContext,
) {
    let caller = ctx.sender();
    assert!(is_admin(control, caller), ENotAdmin);

    assert!(address_list.length() <= 50, EInvalidQuantity);

    assert!(address_list.length() + control.counter <= MAX_SUPPLY, EMintTooMany);

    while (!address_list.is_empty()) {
        let user = address_list.pop_back();
        let (mut kiosk, kiosk_cap) = kiosk::new(ctx);

        mint_to_address(
            control,
            attributes_mapping,
            random,
            &mut kiosk,
            &kiosk_cap,
            transfer_policy,
            user,
            ctx,
        );

        transfer::public_share_object(kiosk);
        transfer::public_transfer(kiosk_cap, user);
    };

    address_list.destroy_empty();
}
