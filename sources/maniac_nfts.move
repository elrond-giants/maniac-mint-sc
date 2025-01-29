module maniac_nfts::maniac_nfts;

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
use sui::package;
use sui::random::Random;
use sui::sui::SUI;
use sui::url::{Self, Url};

// TODO: Change this before deploy to mainnet
const MAX_SUPPLY: u64 = 100;
const IMAGE_BASE_URL: vector<u8> =
    b"https://base-metadata-api-testnet.vercel.app/api/image-sui/?id=";
const NFT_BASE_NAME: vector<u8> = b"Fever Maniac #";
const ONE_SUI: u64 = 1000000000;

// Errors
const EInvalidQuantity: u64 = 0;
const EMintTooMany: u64 = 1;
const EInvalidPayment: u64 = 2;

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

    // Claim the `Publisher` for the package!
    let publisher = package::claim(otw, ctx);

    // Get a new `Display` object for the `Hero` type.
    let mut display = display::new_with_fields<ManiacNft>(
        &publisher,
        keys,
        values,
        ctx,
    );

    // Commit first version of `Display` to apply changes.
    display.update_version();

    transfer::public_transfer(publisher, ctx.sender());
    transfer::public_transfer(display, ctx.sender());

    let mintingControl = MintingControl {
        id: object::new(ctx),
        admin: Admin { admin_address: ctx.sender() },
        counter: 0,
        paused: false, // TODO: Change this to true before deploy to mainnet
        price_wl: 1 * ONE_SUI,
        price_public: 2 * ONE_SUI,
    };

    transfer::share_object(mintingControl);
}

#[allow(lint(self_transfer))]
fun mint_to_sender(
    control: &mut MintingControl,
    attributes_mapping: &AttributeMapping,
    random: &Random,
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
    let sender = ctx.sender();
    transfer::public_transfer(nft, sender);

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

    while (i < quantity) {
        mint_to_sender(control, attributes_mapping, random, ctx);
        i = i + 1;
    };

    if (referral.is_some()) {
        let referralAddress = referral.get_with_default(ctx.sender());
        let referralValue = coin.value() * 7 / 100; // TODO: Change this
        let referralCoin = coin::take(coin.balance_mut(), referralValue, ctx);
        transfer::public_transfer(referralCoin, referralAddress);
    };

    transfer::public_transfer(coin, ctx.sender());
    // transfer::public_transfer(coin, control.admin.admin_address);
}

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

    while (i < quantity) {
        mint_to_sender(control, attributes_mapping, random, ctx);
        i = i + 1;
    };

    transfer::public_transfer(coin, control.admin.admin_address);
}

#[allow(lint(self_transfer))]
public fun set_attribute(
    nft: &mut ManiacNft,
    mut add_attributes: vector<ManiacAttributeNft>,
    mut remove_attributes: vector<vector<u8>>,
    ctx: &mut TxContext,
) {
    assert!(add_attributes.length() <= 5, 1);
    assert!(remove_attributes.length() <= 5, 1);
    assert!(add_attributes.length() > 0 || remove_attributes.length() > 0, 1);

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
