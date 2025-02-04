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
use std::string;
use sui::coin::{Self, Coin};
use sui::display;
use sui::dynamic_object_field as ofield;
use sui::kiosk::{Self, Kiosk, KioskOwnerCap};
use sui::package;
use sui::random::Random;
use sui::sui::SUI;
use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap};
use sui::url::{Self, Url};

// TODO: Change this before deploy to mainnet
const MAX_SUPPLY: u64 = 100;
const IMAGE_BASE_URL: vector<u8> = b"https://metadata.coinfever.app/api/image/?id=";
const NFT_BASE_NAME: vector<u8> = b"Fever Maniac #";
const ONE_SUI: u64 = 1000000000;
const ROYALTIES: u16 = 10_00; // 10%
const MIN_ROYALTIES: u64 = ONE_SUI / 10; // 0.1 SUI

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
    transfer_policy: TransferPolicy<ManiacNft>,
    transfer_policy_cap: TransferPolicyCap<ManiacNft>,
}

public struct MANIAC_NFTS has drop {}

public struct ManiacNftAttributes has store {
    background: string::String,
    body: string::String,
    hat: string::String,
    beard: string::String,
    eyes: string::String,
}

public struct ManiacNft has key, store {
    id: UID,
    name: string::String,
    image_url: Url,
    attributes: ManiacNftAttributes,
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
        price_wl: 1 * ONE_SUI,
        price_public: 2 * ONE_SUI,
        transfer_policy: policy,
        transfer_policy_cap: policy_cap, // TODO: Maybe transfer this to admin
    };

    transfer::public_transfer(publisher, sender);
    transfer::public_transfer(display, sender);
    transfer::share_object(mintingControl);
}

/*
Allows the admin to withdraw royalties from the transfer policy.
*/
entry fun withdraw_royalty(control: &mut MintingControl, ctx: &mut TxContext) {
    let caller = ctx.sender();
    assert!(is_admin(control, caller), ENotAdmin);

    let coin = transfer_policy::withdraw(
        &mut control.transfer_policy,
        &control.transfer_policy_cap,
        option::none(),
        ctx,
    );

    transfer::public_transfer(coin, control.admin.admin_address);
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

    let nft = ManiacNft {
        id: nftId,
        name: string::utf8(fullName),
        image_url: url::new_unsafe_from_bytes(imageUrl),
        attributes: ManiacNftAttributes {
            background: string::utf8(b"None"),
            body: string::utf8(b"None"),
            hat: string::utf8(b"None"),
            beard: string::utf8(b"None"),
            eyes: string::utf8(b"None"),
        },
    };

    control.counter = control.counter + 1;

    kiosk::lock(kiosk, kiosk_cap, &control.transfer_policy, nft);

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
    mut coin: Coin<SUI>,
    quantity: u64,
    referral: Option<address>,
    ctx: &mut TxContext,
) {
    assert!(quantity > 0 && quantity <= 50, EInvalidQuantity);

    assert!(quantity + control.counter <= MAX_SUPPLY, EMintTooMany);

    assert!(coin.value() == quantity * control.price_public, EInvalidPayment);

    let mut i = 0;

    let sender = ctx.sender();
    let (mut kiosk, kiosk_cap) = kiosk::new(ctx);

    while (i < quantity) {
        mint_to_address(control, attributes_mapping, random, &mut kiosk, &kiosk_cap, sender, ctx);
        i = i + 1;
    };

    if (referral.is_some()) {
        let referralAddress = referral.get_with_default(ctx.sender());
        let referralValue = coin.value() * 7 / 100; // TODO: Change this
        let referralCoin = coin::take(coin.balance_mut(), referralValue, ctx);
        transfer::public_transfer(referralCoin, referralAddress);
    };

    // transfer::public_transfer(coin, ctx.sender());
    transfer::public_transfer(coin, control.admin.admin_address);

    transfer::public_share_object(kiosk);
    transfer::public_transfer(kiosk_cap, sender);
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
    ctx: &mut TxContext,
) {
    assert!(quantity > 0 && quantity <= 50, EInvalidQuantity);

    assert!(quantity + control.counter <= MAX_SUPPLY, EMintTooMany);

    assert!(coin.value() == quantity * control.price_wl, EInvalidPayment);

    let mut i = 0;
    let sender = ctx.sender();
    let (mut kiosk, kiosk_cap) = kiosk::new(ctx);

    while (i < quantity) {
        mint_to_address(control, attributes_mapping, random, &mut kiosk, &kiosk_cap, sender, ctx);
        i = i + 1;
    };

    transfer::public_transfer(coin, control.admin.admin_address);
    transfer::public_share_object(kiosk);
    transfer::public_transfer(kiosk_cap, sender);
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

        if (name == b"background") {
            nft.attributes.background = string::utf8(*value);
        } else if (name == b"body") {
            nft.attributes.body = string::utf8(*value);
        } else if (name == b"hat") {
            nft.attributes.hat = string::utf8(*value);
        } else if (name == b"beard") {
            nft.attributes.beard = string::utf8(*value);
        } else if (name == b"eyes") {
            nft.attributes.eyes = string::utf8(*value);
        };

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
    ctx: &mut TxContext,
) {
    let caller = ctx.sender();
    assert!(is_admin(control, caller), ENotAdmin);

    assert!(address_list.length() <= 50, EInvalidQuantity);

    assert!(address_list.length() + control.counter <= MAX_SUPPLY, EMintTooMany);

    while (!address_list.is_empty()) {
        let user = address_list.pop_back();
        let (mut kiosk, kiosk_cap) = kiosk::new(ctx);

        mint_to_address(control, attributes_mapping, random, &mut kiosk, &kiosk_cap, user, ctx);

        transfer::public_share_object(kiosk);
        transfer::public_transfer(kiosk_cap, user);
    };

    address_list.destroy_empty();
}
