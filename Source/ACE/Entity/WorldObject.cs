﻿using ACE.Entity.Enum;
using ACE.Network;
using ACE.Network.Enum;
using System.Collections.Generic;
using ACE.Network.Sequence;
using System.IO;
using ACE.Managers;
using ACE.Network.GameMessages.Messages;

namespace ACE.Entity
{
    public abstract class WorldObject
    {
        public ObjectGuid Guid { get; }

        public ObjectType Type { get; protected set; }

        /// <summary>
        /// wcid - stands for weenie class id
        /// </summary>
        public WeenieClass WeenieClassid { get; protected set; }

        public ushort Icon { get; set; }

        public string Name { get; protected set; }

        /// <summary>
        /// tick-stamp for the last time this object changed in any way.
        /// </summary>
        public double LastUpdatedTicks { get; set; }

        public virtual Position Position
        {
            get { return PhysicsData.Position; }
            protected set { PhysicsData.Position = value; }
        }

        public ObjectDescriptionFlag DescriptionFlags { get; protected set; }

        public WeenieHeaderFlag WeenieFlags { get; protected set; }

        public WeenieHeaderFlag2 WeenieFlags2 { get; protected set; }

        public ushort MovementIndex
        {
            get { return PhysicsData.PositionSequence; }
            set { PhysicsData.PositionSequence = value; }
        }

        public ushort TeleportIndex
        {
            get { return PhysicsData.PortalSequence; }
            set { PhysicsData.PortalSequence = value; }
        }

        public virtual float ListeningRadius { get; protected set; } = 5f;

        public ModelData ModelData { get; }

        public PhysicsData PhysicsData { get; }

        public GameData GameData { get; }

        public bool IsContainer { get; set; } = false;

        private readonly Dictionary<ObjectGuid, WorldObject> inventory = new Dictionary<ObjectGuid, WorldObject>();

        private readonly object inventoryMutex = new object();

        public SequenceManager Sequences { get; }

        public UpdatePositionFlag UpdatePositionFlags { get; set; }

        protected WorldObject(ObjectType type, ObjectGuid guid)
        {
            Type = type;
            Guid = guid;

            GameData = new GameData();
            ModelData = new ModelData();
            PhysicsData = new PhysicsData();

            Sequences = new SequenceManager();
            Sequences.AddSequence(SequenceType.MotionMessage, new UShortSequence());
            Sequences.AddSequence(SequenceType.Motion, new UShortSequence());
            Sequences.AddSequence(SequenceType.ServerControl, new UShortSequence());
        }

        public void AddToInventory(WorldObject worldObject)
        {
            lock (inventoryMutex)
            {
                if (inventory.ContainsKey(worldObject.Guid))
                    return;

                inventory.Add(worldObject.Guid, worldObject);
            }
        }

        public void RemoveFromInventory(ObjectGuid objectGuid)
        {
            lock (inventoryMutex)
            {
                if (inventory.ContainsKey(objectGuid))
                    inventory.Remove(objectGuid);
            }
        }

        public void HandleDropItem(ObjectGuid objectGuid, Session session)
        {
            lock (this.inventoryMutex)
            {
                if (!this.inventory.ContainsKey(objectGuid)) return;
                var obj = this.inventory[objectGuid];
                this.GameData.Burden = obj.GameData.Burden;

                // TODO: Not sure if the next two lines need to be here.
                obj.GameData.ContainerId = 0;
                obj.PhysicsData.Position = PhysicsData.Position.InFrontOf(1.50f);
                obj.PhysicsData.PhysicsDescriptionFlag = PhysicsDescriptionFlag.Position;

                // TODO: Send the last part of the sequence.   GameMessageUpdatePosition - I am doing something wrong here 

                obj.UpdatePositionFlags = UpdatePositionFlag.Contact | UpdatePositionFlag.Placement | UpdatePositionFlag.NoQuaternionY  | UpdatePositionFlag.NoQuaternionX;
                session.Network.EnqueueSend(new GameMessageUpdatePosition(obj));

                LandblockManager.AddObject(obj);
                this.inventory.Remove(objectGuid);
            }
        }
        public void GetInventoryItem(ObjectGuid objectGuid, out WorldObject worldObject)
        {
            lock (inventoryMutex)
            {
                inventory.TryGetValue(objectGuid, out worldObject);
            }
        }

        public virtual void SerializeUpdateObject(BinaryWriter writer)
        {
            // content of these 2 is the same? TODO: Validate that?
            SerializeCreateObject(writer);
        }

        public virtual void SerializeCreateObject(BinaryWriter writer)
        {
            writer.WriteGuid(Guid);

            ModelData.Serialize(writer);
            PhysicsData.Serialize(writer);

            writer.Write((uint)WeenieFlags);
            writer.WriteString16L(Name);
            writer.Write((ushort)WeenieClassid);
            writer.Write((ushort)Icon);
            writer.Write((uint)Type);
            writer.Write((uint)DescriptionFlags);

            if ((DescriptionFlags & ObjectDescriptionFlag.AdditionFlags) != 0)
                writer.Write((uint)WeenieFlags2);

            if ((WeenieFlags & WeenieHeaderFlag.PuralName) != 0)
                writer.WriteString16L(GameData.NamePlural);

            if ((WeenieFlags & WeenieHeaderFlag.ItemCapacity) != 0)
                writer.Write(GameData.ItemCapacity);

            if ((WeenieFlags & WeenieHeaderFlag.ContainerCapacity) != 0)
                writer.Write(GameData.ContainerCapacity);

            if ((WeenieFlags & WeenieHeaderFlag.AmmoType) != 0)
                writer.Write((ushort)GameData.AmmoType);

            if ((WeenieFlags & WeenieHeaderFlag.Value) != 0)
                writer.Write(GameData.Value);

            if ((WeenieFlags & WeenieHeaderFlag.Usable) != 0)
                writer.Write((uint)GameData.Usable);

            if ((WeenieFlags & WeenieHeaderFlag.UseRadius) != 0)
                writer.Write(GameData.UseRadius);

            if ((WeenieFlags & WeenieHeaderFlag.TargetType) != 0)
                writer.Write((uint)GameData.TargetType);

            if ((WeenieFlags & WeenieHeaderFlag.UiEffects) != 0)
                writer.Write((uint)GameData.UiEffects);

            if ((WeenieFlags & WeenieHeaderFlag.CombatUse) != 0)
                writer.Write((byte)GameData.CombatUse);

            if ((WeenieFlags & WeenieHeaderFlag.Struture) != 0)
                writer.Write((ushort)GameData.Struture);

            if ((WeenieFlags & WeenieHeaderFlag.MaxStructure) != 0)
                writer.Write((ushort)GameData.MaxStructure);

            if ((WeenieFlags & WeenieHeaderFlag.StackSize) != 0)
                writer.Write(GameData.StackSize);

            if ((WeenieFlags & WeenieHeaderFlag.MaxStackSize) != 0)
                writer.Write(GameData.MaxStackSize);

            if ((WeenieFlags & WeenieHeaderFlag.Container) != 0)
                writer.Write(GameData.ContainerId);

            if ((WeenieFlags & WeenieHeaderFlag.Wielder) != 0)
                writer.Write(GameData.Wielder);

            if ((WeenieFlags & WeenieHeaderFlag.ValidLocations) != 0)
                writer.Write((uint)GameData.ValidLocations);

            if ((WeenieFlags & WeenieHeaderFlag.Location) != 0)
                writer.Write((uint)GameData.Location);

            if ((WeenieFlags & WeenieHeaderFlag.Priority) != 0)
                writer.Write((uint)GameData.Priority);

            if ((WeenieFlags & WeenieHeaderFlag.BlipColour) != 0)
                writer.Write((byte)GameData.RadarColour);

            if ((WeenieFlags & WeenieHeaderFlag.Radar) != 0)
                writer.Write((byte)GameData.RadarBehavior);

            if ((WeenieFlags & WeenieHeaderFlag.Script) != 0)
                writer.Write(GameData.Script);

            if ((WeenieFlags & WeenieHeaderFlag.Workmanship) != 0)
                writer.Write(GameData.Workmanship);

            if ((WeenieFlags & WeenieHeaderFlag.Burden) != 0)
                writer.Write(GameData.Burden);

            if ((WeenieFlags & WeenieHeaderFlag.Spell) != 0)
                writer.Write(GameData.Spell);

            if ((WeenieFlags & WeenieHeaderFlag.HouseOwner) != 0)
                writer.Write(GameData.HouseOwner);

            /*if ((WeenieFlags & WeenieHeaderFlag.HouseRestrictions) != 0)
            {
            }*/

            if ((WeenieFlags & WeenieHeaderFlag.HookItemTypes) != 0)
                writer.Write(GameData.HookItemTypes);

            if ((WeenieFlags & WeenieHeaderFlag.Monarch) != 0)
                writer.Write(GameData.Monarch);

            if ((WeenieFlags & WeenieHeaderFlag.HookType) != 0)
                writer.Write(GameData.HookType);

            if ((WeenieFlags & WeenieHeaderFlag.IconOverlay) != 0)
                writer.Write(GameData.IconOverlay);

            /*if ((WeenieFlags2 & WeenieHeaderFlag2.IconUnderlay) != 0)
                writer.Write((ushort)0);*/

            if ((WeenieFlags & WeenieHeaderFlag.Material) != 0)
                writer.Write((uint)GameData.Material);

            /*if ((WeenieFlags2 & WeenieHeaderFlag2.Cooldown) != 0)
                writer.Write(0u);*/

            /*if ((WeenieFlags2 & WeenieHeaderFlag2.CooldownDuration) != 0)
                writer.Write(0.0d);*/

            /*if ((WeenieFlags2 & WeenieHeaderFlag2.PetOwner) != 0)
                writer.Write(0u);*/

            writer.Align();
        }

        public void WriteUpdatePositionPayload(BinaryWriter writer)
        {
            writer.WriteGuid(Guid);
            writer.Write((uint)UpdatePositionFlags);

            Position.Serialize(writer, false);

            if ((UpdatePositionFlags & UpdatePositionFlag.NoQuaternionW) == 0)
                writer.Write(Position.Facing.W);
            if ((UpdatePositionFlags & UpdatePositionFlag.NoQuaternionX) == 0)
                writer.Write(Position.Facing.X);
            if ((UpdatePositionFlags & UpdatePositionFlag.NoQuaternionY) == 0)
                writer.Write(Position.Facing.Y);
            if ((UpdatePositionFlags & UpdatePositionFlag.NoQuaternionZ) == 0)
                writer.Write(Position.Facing.Z);

            if ((UpdatePositionFlags & UpdatePositionFlag.Velocity) != 0)
            {

            }

            // ToDo: Need to fix this - hardcoded for now.
            if ((UpdatePositionFlags & UpdatePositionFlag.Placement) != 0)
                writer.Write((uint)0x12345678);

            var player = Guid.IsPlayer() ? this as Player : null;
            writer.Write((player?.TotalLogins ?? (ushort)0x1234));
            //writer.Write(++MovementIndex);
            //writer.Write(TeleportIndex);
            writer.Write((ushort)0x1234);
            writer.Write((ushort)0x1234);
        }
    }
}