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
use sui::event;
use sui::kiosk::{Self, Kiosk, KioskOwnerCap};
use sui::package;
use sui::random::Random;
use sui::sui::SUI;
use sui::table::{Self, Table};
use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap};
use sui::vec_map::{Self, VecMap};

// === Errors ===

const EInvalidQuantity: u64 = 0;
const EMintTooMany: u64 = 1;
const EInvalidPayment: u64 = 2;
const ENotAdmin: u64 = 3;
const EInvalidMintingType: u64 = 4;
const ENameAlreadyUsed: u64 = 5;

// === Constants ===

const MAX_SUPPLY: u64 = 4444;
const IMAGE_BASE_URL: vector<u8> = b"https://metadata.coinfever.app/api/image/?id=";
const NFT_BASE_NAME: vector<u8> = b"Fever Maniac #";
const WL_PRICE: u64 = 12;
const PUBLIC_PRICE: u64 = 15;
const ONE_SUI: u64 = 1000000000;
const ROYALTIES: u16 = 7_00; // 10%
const MIN_ROYALTIES: u64 = ONE_SUI / 10; // 0.1 SUI

const MAX_MINT_WL: u64 = 6;
const MAX_MINT_PUBLIC: u64 = 12;

// === Structs ===

public struct ManiacNft has key, store {
    id: UID,
    name: String,
    image_url: String,
    attributes: VecMap<String, String>,
}

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
    minting_type: u8, // 0 = WL | 1 = Public
    wl_address_counter: Table<address, u64>,
    public_address_counter: Table<address, u64>,
    used_names: VecMap<String, bool>,
}

public struct MANIAC_NFTS has drop {}

// === Events ===

public struct AttributeChanged has copy, drop {
    nft_id: ID,
    add_attributes: vector<ID>,
    remove_attributes: vector<vector<u8>>,
}

public struct NameChanged has copy, drop {
    nft_id: ID,
    new_name: vector<u8>,
}

// === Public Functions ===

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
        paused: true,
        price_wl: WL_PRICE * ONE_SUI,
        price_public: PUBLIC_PRICE * ONE_SUI,
        minting_type: 0,
        wl_address_counter: table::new(ctx),
        public_address_counter: table::new(ctx),
        used_names: vec_map::empty<String, bool>(),
    };

    transfer::public_transfer(publisher, sender);
    transfer::public_transfer(display, sender);
    transfer::share_object(mintingControl);
    transfer::public_share_object(policy);
    transfer::public_transfer(policy_cap, sender);
}

/*
Pause the minting (only callable by the admin)
*/
entry fun pause(control: &mut MintingControl, ctx: &TxContext) {
    let caller = ctx.sender();
    assert!(is_admin(control, caller), ENotAdmin);
    control.paused = true;
}

/*
Unpause the contract (only callable by the admin)
*/
entry fun unpause(control: &mut MintingControl, ctx: &TxContext) {
    let caller = ctx.sender();
    assert!(is_admin(control, caller), ENotAdmin);
    control.paused = false;
}

/*
Pause the minting (only callable by the admin)
*/
entry fun set_mint_type_wl(control: &mut MintingControl, ctx: &TxContext) {
    let caller = ctx.sender();
    assert!(is_admin(control, caller), ENotAdmin);
    control.minting_type = 0;
}

/*
Unpause the contract (only callable by the admin)
*/
entry fun set_mint_type_public(control: &mut MintingControl, ctx: &TxContext) {
    let caller = ctx.sender();
    assert!(is_admin(control, caller), ENotAdmin);
    control.minting_type = 1;
}

/*
Allows the admin to withdraw royalties from the transfer policy.
*/
entry fun withdraw_royalty(
    control: &MintingControl,
    transfer_policy: &mut TransferPolicy<ManiacNft>,
    policy_cap: &TransferPolicyCap<ManiacNft>,
    ctx: &mut TxContext,
) {
    let caller = ctx.sender();
    assert!(is_admin(control, caller), ENotAdmin);

    let coin = transfer_policy::withdraw(
        transfer_policy,
        policy_cap,
        option::none(),
        ctx,
    );

    transfer::public_transfer(coin, control.admin.admin_address);
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
    assert!(control.minting_type == 1, EInvalidMintingType);

    assert!(quantity > 0 && quantity <= MAX_MINT_PUBLIC, EInvalidQuantity);

    assert!(quantity + control.counter <= MAX_SUPPLY, EMintTooMany);

    assert!(coin.value() == quantity * control.price_public, EInvalidPayment);

    let sender = ctx.sender();
    if (control.public_address_counter.contains(sender)) {
        let counter = *control.public_address_counter.borrow(sender);
        assert!(counter + quantity <= MAX_MINT_PUBLIC, EMintTooMany);
        control.public_address_counter.remove(sender);
        control.public_address_counter.add(sender, counter + quantity);
    } else {
        control.public_address_counter.add(sender, quantity);
    };

    let mut i = 0;

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
Whitelist mint function.
*/
entry fun mint_wl(
    control: &mut MintingControl,
    attributes_mapping: &AttributeMapping,
    random: &Random,
    _wl: &WlNft,
    coin: Coin<SUI>,
    quantity: u64,
    kiosk: &mut Kiosk,
    kiosk_cap: &KioskOwnerCap,
    transfer_policy: &TransferPolicy<ManiacNft>,
    ctx: &mut TxContext,
) {
    assert!(control.minting_type == 0, EInvalidMintingType);

    assert!(quantity > 0 && quantity <= MAX_MINT_WL, EInvalidQuantity);

    assert!(quantity + control.counter <= MAX_SUPPLY, EMintTooMany);

    assert!(coin.value() == quantity * control.price_wl, EInvalidPayment);

    let sender = ctx.sender();
    if (control.wl_address_counter.contains(sender)) {
        let counter = *control.wl_address_counter.borrow(sender);
        assert!(counter + quantity <= MAX_MINT_WL, EMintTooMany);
        control.wl_address_counter.remove(sender);
        control.wl_address_counter.add(sender, counter + quantity);
    } else {
        control.wl_address_counter.add(sender, quantity);
    };

    let mut i = 0;

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

            nft.attributes.remove(&string::utf8(name));
            nft.attributes.insert(string::utf8(name), string::utf8(b"None"));
        };
    };

    let mut attribute_ids = vector::empty<ID>();

    while (!add_attributes.is_empty()) {
        let attribute = add_attributes.pop_back();
        attribute_ids.push_back(object::id(&attribute));
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

        ofield::add(&mut nft.id, *name, attribute);
    };

    event::emit(AttributeChanged {
        nft_id,
        add_attributes: attribute_ids,
        remove_attributes,
    });

    add_attributes.destroy_empty();
    remove_attributes.destroy_empty();
}

entry fun set_name(
    control: &mut MintingControl,
    nft_id: ID,
    kiosk: &mut Kiosk,
    cap: &KioskOwnerCap,
    new_name: vector<u8>,
) {
    let new_name_string = string::utf8(new_name);
    assert!(control.used_names.contains(&new_name_string) == false, ENameAlreadyUsed);

    let nft = kiosk::borrow_mut<ManiacNft>(kiosk, cap, nft_id);
    let old_name = nft.name;
    nft.name = new_name_string;

    control.used_names.remove(&old_name);
    control.used_names.insert(new_name_string, true);

    event::emit(NameChanged {
        nft_id,
        new_name,
    });
}

// === View Functions ===

public fun name(nft: &ManiacNft): &String {
    &nft.name
}

public fun image_url(nft: &ManiacNft): &String {
    &nft.image_url
}

public fun attributes(nft: &ManiacNft): &VecMap<String, String> {
    &nft.attributes
}

// === Admin Functions ===

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

entry fun giveaway_to_sender(
    control: &mut MintingControl,
    attributes_mapping: &AttributeMapping,
    random: &Random,
    kiosk: &mut Kiosk,
    kiosk_cap: &KioskOwnerCap,
    quantity: u64,
    transfer_policy: &TransferPolicy<ManiacNft>,
    ctx: &mut TxContext,
) {
    let caller = ctx.sender();
    assert!(is_admin(control, caller), ENotAdmin);

    assert!(quantity + control.counter <= MAX_SUPPLY, EMintTooMany);

    let mut i = 0;

    while (i < quantity) {
        mint_to_address(
            control,
            attributes_mapping,
            random,
            kiosk,
            kiosk_cap,
            transfer_policy,
            caller,
            ctx,
        );

        i = i + 1;
    };
}

// === Private Functions ===

fun is_admin(control: &MintingControl, caller: address): bool {
    control.admin.admin_address == caller
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
    _sender: address,
    ctx: &mut TxContext,
) {
    let mut full_name = vector::empty();
    full_name.append(NFT_BASE_NAME);
    full_name.append(*control.counter.to_string().as_bytes());

    let nft_id = object::new(ctx);

    let mut image_url = IMAGE_BASE_URL;
    let objectIdString = nft_id.to_address().to_string().as_bytes();
    image_url.append(*objectIdString);

    control.counter = control.counter + 1;

    let backgroundAttribute = create_random_attribute(
        attributes_mapping,
        b"background",
        random,
        ctx,
    );
    // transfer::public_transfer(backgroundAttribute, sender);
    let beardAttribute = create_random_attribute(attributes_mapping, b"beard", random, ctx);
    // transfer::public_transfer(beardAttribute, sender);
    let bodyAttribute = create_random_attribute(attributes_mapping, b"body", random, ctx);
    // transfer::public_transfer(bodyAttribute, sender);
    let hatAttribute = create_random_attribute(attributes_mapping, b"hat", random, ctx);
    // transfer::public_transfer(hatAttribute, sender);
    let eyesAttribute = create_random_attribute(attributes_mapping, b"eyes", random, ctx);
    // transfer::public_transfer(eyesAttribute, sender);

    let mut attributes = vec_map::empty<String, String>();
    attributes.insert(string::utf8(b"background"), *backgroundAttribute.field_value());
    attributes.insert(string::utf8(b"body"), *bodyAttribute.field_value());
    attributes.insert(string::utf8(b"hat"), *hatAttribute.field_value());
    attributes.insert(string::utf8(b"beard"), *beardAttribute.field_value());
    attributes.insert(string::utf8(b"eyes"), *eyesAttribute.field_value());

    let nft = ManiacNft {
        id: nft_id,
        name: string::utf8(full_name),
        image_url: string::utf8(image_url),
        attributes,
    };

    let nft_inner_id = nft.id.to_inner();

    kiosk::lock(kiosk, kiosk_cap, transfer_policy, nft);

    // Equip attributes to Fever Maniac NFT
    let mut attributes = vector::empty();
    attributes.push_back(backgroundAttribute);
    attributes.push_back(beardAttribute);
    attributes.push_back(bodyAttribute);
    attributes.push_back(hatAttribute);
    attributes.push_back(eyesAttribute);
    let removeAttributes = vector::empty<vector<u8>>();

    set_attribute(nft_inner_id, kiosk, kiosk_cap, attributes, removeAttributes, ctx);
}
