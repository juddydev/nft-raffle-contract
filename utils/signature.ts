import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ethers } from "hardhat";

export async function signMessage(signer: SignerWithAddress, types: string[], data: any[]) {
  let message = ethers.utils.solidityPack(types, data);
  message = ethers.utils.solidityKeccak256(["bytes"], [message]);
  const signature = await signer.signMessage(ethers.utils.arrayify(message));

  return signature;
}