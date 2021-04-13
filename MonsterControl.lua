--Man hunt monster controlling script
--by NSKuber

--preliminary setup

local worldInfo = worldGlobals.worldInfo
if worldInfo:IsMenuSimulationWorld() then return end

if worldInfo:IsInputNonExclusive() then
  worldInfo:SetNonExclusiveInput(false)
end

if worldGlobals.NSKuberIsBFE then
  worldGlobals.MonsterControlFOV = 75
else
  worldGlobals.MonsterControlFOV = 90
end

dofile("Content/Shared/Scripts/MonsterControl/TargetMarkers.lua")
dofile("Content/Shared/Scripts/MonsterControl/MonstersTable.lua")

local Pi = 3.14159265359
local qNull = mthHPBToQuaternion(0,0,0)
local QV = function(x,y,z,h,p,b)
  return mthQuatVect(mthHPBToQuaternion(h,p,b),mthVector3f(x,y,z))
end
local qvNowhere = QV(324,3434,63,0,0,0)

--player : CPlayerPuppetEntity
--puppet : CLeggedCharacterEntity

worldGlobals.MonsterControlTemplates = LoadResource("Content/Shared/Scripts/Templates/MonsterControl/ControllingStuff.rsc")
worldGlobals.MonsterControl_MonsterTemplates = LoadResource("Content/Shared/Scripts/Templates/MonsterControl/Monsters.rsc")

local WargablePuppetClasses = {
  ["CLeggedCharacterEntity"] = true,
  ["CSpiderPuppetEntity"] = true,
  ["CCaveDemonPuppetEntity"] = true,
  ["CPsykickPuppetEntity"] = true,
  ["CKhnumPuppetEntity"] = true,
  ["CAircraftCharacterEntity"] = true,
  ["CAutoTurretEntity"] = true,
  ["CScrapJackBossPuppetEntity"] = true,
  ["CUghZanPuppetEntity"] = true,
  ["CRollingBallCharacterEntity"] = true,
  ["CSS1LavaElementalPuppetEntity"] = true,     
  ["CSS1CannonRotatingEntity"] = true,   
  ["CSS1CannonStaticEntity"] = true,  
  ["CSS1ExotechLarvaPuppetEntity"] = true,  
  ["CSS1KukulkanPuppetEntity"] = true,
  ["CSS1SummonerPuppetEntity"] = true,
  ["CSS1UghZanPuppetEntity"] = true,
} 

local EnemyPuppetClasses = {
  ["CPlayerPuppetEntity"] = true,
  ["CPlayerBotPuppetEntity"] = true,  
}

local MonsterSpawners = {}
if worldGlobals.netIsHost then
  MonsterSpawners[0] = worldGlobals.MonsterControl_MonsterTemplates:SpawnEntityFromTemplateByName("FakeFoe",worldGlobals.worldInfo,qvNowhere)
  MonsterSpawners[0] = MonsterSpawners[0]:GetEffectiveEntity()
end

local lookTargetShiftBase = mthNormalize(mthVector3f(0,-15,-10))

local selectedWargableBias = mthVector3f(0,20,0)
local selectedEnemyBias = mthVector3f(20,5,0)
local selectedUnwargableBias = mthVector3f(15,20,0)
local controlledFriendlyBias = mthVector3f(0,1,2)
local controlledEnemyBias = mthVector3f(2,0.5,0)

local fTargetDistanceBase = 30
local fTargetDistanceMinBase = 6
local fTargetDistanceMax = 100
local fTargetDistanceStepMultiplier = 1.15
local fCameraMoveSpeed = 30
local fCameraRotationPerScreen = 2*Pi
local fWargInCooldown = 1.5

if (worldInfo:GetGameMode() == "ControlManHunt") then
  lookTargetShiftBase = mthNormalize(mthVector3f(0,-30,-10))
end

local localPlayer

local ControlsTFX = LoadResource("Content/Shared/Scripts/Templates/MonsterControl/Presets/Controls.tfx")
local MonsterInfoTFX = LoadResource("Content/Shared/Scripts/Templates/MonsterControl/Presets/MonsterInfo.tfx")
local WarningTFX = LoadResource("Content/Shared/Scripts/Templates/MonsterControl/Presets/Warning.tfx")

local CommandToText = {["altFire"] = "Alt-Fire",["shiftAltFire"] = "Shift+Alt-Fire",
  ["shiftFire"] = "Shift+Fire",["jump"] = "Jump",["reload"] = "Reload",}

local MonsterFeatures = worldGlobals.MonsterControl_MonsterFeatures

local AvalilableInputs = {"shiftFire","altFire","shiftAltFire","jump","reload"}


--Function performing a cast ray from the mouse position to the ground
local CastRayToMouse = function(player,strRayType,fRayWidth)
  
  local origin = player:GetLookOrigin():GetVect()
  local lookDir = player:GetLookOrigin():GetQuat()
  
  local width = fRayWidth
  if (width == nil) then width = 0 end
  
  local stretch = mthTanF(worldGlobals.MonsterControlFOV/360*Pi) * 9/16
  local boxSize = mthVector3f(2*stretch/9*16,2*stretch,0)    
  local dirZ = mthQuaternionToDirection(lookDir)
  local qvZ = mthQuatVect(lookDir,mthVector3f(0,0,0))
  local ZrotX = mthQuatVect(mthHPBToQuaternion(-Pi/2,0,0),mthVector3f(0,0,0))
  local dirX = mthQuaternionToDirection(mthMulQV(qvZ,ZrotX):GetQuat())*boxSize.x
  local dirY = mthNormalize(mthCrossV3f(dirZ,dirX))*boxSize.y

  local vMouse = worldInfo:GetMousePosition()
  if not worldInfo:IsInputNonExclusive() then vMouse = mthVector3f(100000,0,100000) end
  local vPlace = origin+2*(dirZ-dirX/2-dirY/2 + dirX*vMouse.x/GetGameScreenWidth() + dirY*vMouse.y/GetGameScreenHeight())
  
  return CastRay(player,player,vPlace,mthNormalize(vPlace-origin),10000,width,strRayType)
  
end

local IsMonsterBusy = {}

--'monster busy' visual effect
local SpawnBusyEffect = function(puppet)
RunAsync(function()
  if not IsDeleted(busyEffect) then busyEffect:Delete() end
  local qvPlace = puppet:GetPlacement()
  local vBBox = puppet:GetBoundingBoxSize()
  qvPlace.vy = qvPlace.vy + vBBox.y
  local busyEffect = worldGlobals.MonsterControlTemplates:SpawnEntityFromTemplateByName("MonsterBusy",worldInfo,qvPlace)
  vBBox.y = 0
  busyEffect:SetStretch(mthMaxF(mthLenV3f(vBBox)*0.7,1))
  busyEffect:SetParent(puppet,"")

  while not IsDeleted(puppet) do
    if not puppet:IsAlive() then break end
    if (puppet ~= worldGlobals.MonsterControl_LocalControlledMonster) then break end
    if not IsMonsterBusy[puppet] then break end
    Wait(CustomEvent("OnStep"))
  end
  
  if not IsDeleted(busyEffect) then busyEffect:Delete() end
end)
end

--function which synchronizes the attack target of the controlled monster
--from server to all clients
worldGlobals.CreateRPC("server","reliable","MonsterControl_SyncAttackTarget",
function(puppet,enShootEntity,vHitPoint,bContinuous)
  if worldGlobals.netIsHost then return end
  
  IsMonsterBusy[puppet] = true
  
  if (worldGlobals.MonsterControl_LocalControlledMonster == puppet) then
    SpawnBusyEffect(puppet)
  end
  
  if bContinuous then
    
    local className = "None"
    if not IsDeleted(enShootEntity) then
      className = enShootEntity:GetClassName()
    end 
    if WargablePuppetClasses[className] or EnemyPuppetClasses[className] then 
      local boxHeight = mthVector3f(0,enShootEntity:GetBoundingBoxSize().y*0.5,0)
      RunHandled(function()      
        Wait(CustomEvent(puppet,"StopAiming"))
      end,
        
      OnEvery(CustomEvent("OnStep")),
      function()
        if IsDeleted(puppet) then return end
        if not IsDeleted(enShootEntity) then
          puppet:ForceShootPoint(enShootEntity:GetPlacement():GetVect() + boxHeight)
        end
      end)
      
      if not IsDeleted(puppet) then 
        puppet:UnforceShootPoint() 
      end

    else
      puppet:SetDesiredLookDir(mthDirectionVectorToEuler(mthNormalize(vHitPoint-puppet:GetPlacement():GetVect())))
      puppet:ForceShootPoint(vHitPoint)      
    end
   
  else 
    puppet:SetDesiredLookDir(mthDirectionVectorToEuler(mthNormalize(vHitPoint-puppet:GetPlacement():GetVect())))
    puppet:ForceShootPoint(vHitPoint)
  end
     
end)

worldGlobals.CreateRPC("server","reliable","MonsterControl_DropAttackTarget",
function(puppet)
  if worldGlobals.netIsHost then return end
  IsMonsterBusy[puppet] = false
  
  if IsDeleted(puppet) then return end
  puppet:LoseFoe()
  puppet:UnforceShootPoint()
  SignalEvent(puppet,"StopAiming")
end)

--Perform a 'Shoot' attack on a controlled monster
local ShootAttack = function(puppet,ShootInfoTable,enShootEntity,vShootPoint)
  RunAsync(function()
    
    if not worldInfo:IsSinglePlayer() then
      worldGlobals.MonsterControl_SyncAttackTarget(puppet,enShootEntity,vShootPoint,true)
    end
    
    IsMonsterBusy[puppet] = true
    
    if (worldGlobals.MonsterControl_LocalControlledMonster == puppet) then
      SpawnBusyEffect(puppet)
    end    
    
    local strAttackName = ShootInfoTable[2]
    local iAttackCount = ShootInfoTable[3]
    local fPrepareDelay = ShootInfoTable[4]
    
    local className = "None"
    if not IsDeleted(enShootEntity) then
      className = enShootEntity:GetClassName()
    end
    
    if WargablePuppetClasses[className] or EnemyPuppetClasses[className] then
      
      local fakeFoe
      
      local boxHeight = mthVector3f(0,enShootEntity:GetBoundingBoxSize().y*0.666,0)
      RunHandled(function()
        if (fPrepareDelay ~= nil) then Wait(Delay(fPrepareDelay)) end
        --DON'T DELET CAUSE AIMING PROJECTILES
        puppet:DisableNonPlayerFoes(false)
        puppet:EnableAI()
        puppet:ForceFoe(enShootEntity)        
        Wait(puppet:AttackShoot(strAttackName,iAttackCount,false))
      end,
      
      OnEvery(CustomEvent("OnStep")),
      function()
        if IsDeleted(puppet) then return end
        if not IsDeleted(enShootEntity) then
          puppet:ForceShootPoint(enShootEntity:GetPlacement():GetVect() + boxHeight)
        end
      end)
      
      if not IsDeleted(puppet) then
        local vDiff = vShootPoint - puppet:GetPlacement():GetVect()
        vDiff.y = 0
        local qvOrigin = mthQuatVect(qNull,puppet:GetPlacement():GetVect() + mthNormalize(vDiff)*100)
        fakeFoe = MonsterSpawners[0]:SpawnOne()
        fakeFoe:SetPlacement(qvOrigin)
        puppet:LoseFoe()
        puppet:ForceFoe(fakeFoe)              
        --Wait(CustomEvent("OnStep"))
        if not IsDeleted(fakeFoe) then
          fakeFoe:Delete()
        end     
        if not IsDeleted(puppet) then
          puppet:UnforceShootPoint()
          puppet:DisableAI()
          puppet:DisableNonPlayerFoes(true)
          puppet:LoseFoe()
          IsMonsterBusy[puppet] = false
        end
      end
      
    else

      puppet:SetDesiredLookDir(mthDirectionVectorToEuler(mthNormalize(vShootPoint-puppet:GetPlacement():GetVect())))
      puppet:ForceShootPoint(vShootPoint)
      if (fPrepareDelay ~= nil) then Wait(Delay(fPrepareDelay)) end
      Wait(puppet:AttackShoot(strAttackName,iAttackCount,false))
      if not IsDeleted(puppet) then
        puppet:UnforceShootPoint()
        IsMonsterBusy[puppet] = false
      end  
          
    end
    
    if not worldInfo:IsSinglePlayer() then
      worldGlobals.MonsterControl_DropAttackTarget(puppet)
    end    
    
  end)
end

--Perform a 'Melee' attack on a controlled monster
local MeleeAttack = function(puppet,strAttackName,enHitEntity,vHitPoint)
  RunAsync(function()
  
    if not worldInfo:IsSinglePlayer() then
      worldGlobals.MonsterControl_SyncAttackTarget(puppet,enHitEntity,vHitPoint,false)
    end
    
    IsMonsterBusy[puppet] = true
    
    if (worldGlobals.MonsterControl_LocalControlledMonster == puppet) then
      SpawnBusyEffect(puppet)
    end    
    
    local vDiff = vHitPoint - puppet:GetPlacement():GetVect()
    vDiff.y = 0
    local qvOrigin = mthQuatVect(qNull,puppet:GetPlacement():GetVect() + mthNormalize(vDiff)*1000)
    local fakeFoe = MonsterSpawners[0]:SpawnOne()
    fakeFoe:SetPlacement(qvOrigin)
    
    puppet:DisableNonPlayerFoes(false)
    puppet:EnableAI()
    puppet:ForceFoe(fakeFoe)
    puppet:SetDesiredLookDir(mthDirectionVectorToEuler(mthNormalize(vHitPoint-puppet:GetPlacement():GetVect())))
    
    Wait(puppet:AttackMelee(strAttackName))
    
    if not IsDeleted(fakeFoe) then
      fakeFoe:Delete()
    end
        
    if not IsDeleted(puppet) then
      puppet:DisableAI()
      puppet:DisableNonPlayerFoes(true)
      puppet:LoseFoe()
      puppet:PlayAnim("")
      IsMonsterBusy[puppet] = false
    end
    
    if not worldInfo:IsSinglePlayer() then
      worldGlobals.MonsterControl_DropAttackTarget(puppet)
    end          
    
  end)
end

--Perform a 'Jump' attack on a controlled monster
local JumpAttack = function(puppet,strAttackName,enHitEntity,vHitPoint)
  RunAsync(function()
  
    if not worldInfo:IsSinglePlayer() then
      worldGlobals.MonsterControl_SyncAttackTarget(puppet,enHitEntity,vHitPoint,false)
    end  
    
    IsMonsterBusy[puppet] = true
    
    if (worldGlobals.MonsterControl_LocalControlledMonster == puppet) then
      SpawnBusyEffect(puppet)
    end    

    local vDiff = vHitPoint - puppet:GetPlacement():GetVect()
    vDiff.y = 0
    local qvOrigin = mthQuatVect(qNull,puppet:GetPlacement():GetVect() + mthNormalize(vDiff)*1000)
    local fakeFoe = MonsterSpawners[0]:SpawnOne()
    fakeFoe:SetPlacement(qvOrigin)
    
    puppet:DisableNonPlayerFoes(false)
    puppet:EnableAI()
    puppet:ForceFoe(fakeFoe)
    puppet:SetDesiredLookDir(mthDirectionVectorToEuler(mthNormalize(vHitPoint-puppet:GetPlacement():GetVect())))
    Wait(puppet:AttackLeap(strAttackName))
      
    if not IsDeleted(fakeFoe) then
      fakeFoe:Delete()
    end    
    
    if not IsDeleted(puppet) then
      puppet:DisableAI()
      puppet:DisableNonPlayerFoes(true)
      puppet:LoseFoe()
      puppet:PlayAnim("")
      IsMonsterBusy[puppet] = false
    end
    
    if not worldInfo:IsSinglePlayer() then
      worldGlobals.MonsterControl_DropAttackTarget(puppet)
    end          
   
  end)
end

local ControlledMonsters = {}
local ControllingPlayers = {}
local SelectedMonsters = {}
local GoalPoints = {}

worldGlobals.MonsterControl_PlayerAlignments = {}
worldGlobals.MonsterControl_PlayerControlEnabled = {}

local IsMonsterOwned = {}

worldGlobals.CreateRPC("server","reliable","MonsterControl_DropControl",
function(puppet)
  if worldGlobals.netIsHost then return end
  if IsDeleted(puppet) then return end
  SignalEvent(puppet,"DropControl")
end)

--Host-side handling of the controlled monster
local HostHandleControlledMonster = function(controlledMonster)
  RunAsync(function()
    --controlledMonster : CLeggedCharacterEntity
    IsMonsterOwned[controlledMonster] = true
    
    local lookTarget
    
    controlledMonster:DisableAI()
    controlledMonster:DisableNonPlayerFoes(true)
    controlledMonster:DisablePlayerFoes(true)
    controlledMonster:LoseFoe()
    GoalPoints[controlledMonster] = nil
    if not IsDeleted(ControllingPlayers[controlledMonster]) then
      ControllingPlayers[controlledMonster]:SetArmor(0)
      ControllingPlayers[controlledMonster]:SetHealth(mthMaxF(controlledMonster:GetHealth(),1))
    end
    controlledMonster:ReportDamage()
    controlledMonster:PlayAnim("")
    
    RunHandled(function()
      Wait(Any(CustomEvent(controlledMonster,"DropControl"),Event(controlledMonster.Died)))
    end,
    
    OnEvery(Event(controlledMonster.Damaged)),
    function()
      if not IsDeleted(ControllingPlayers[controlledMonster]) then
        ControllingPlayers[controlledMonster]:InflictDamage(0)
        ControllingPlayers[controlledMonster]:SetHealth(mthMaxF(controlledMonster:GetHealth(),1))
      end
      controlledMonster:ReportDamage()
    end,
    
    OnEvery(CustomEvent("OnStep")),
    function()
      if IsDeleted(controlledMonster) then 
        SignalEvent(controlledMonster,"DropControl")
        return
      end
      if not IsMonsterBusy[controlledMonster] then
        
        if (GoalPoints[controlledMonster] ~= nil) then
          controlledMonster:SetGoalPoint(GoalPoints[controlledMonster])
        end
        
        if (controlledMonster:GetFoe() ~= nil) then controlledMonster:LoseFoe() end
        
      end
    end,
    
    OnEvery(CustomEvent("MonsterControl_ShowPlayerNames")),
    function()
      if not IsDeleted(localPlayer) then
        if worldGlobals.MonsterControl_PlayerControlEnabled[localPlayer] then
          
          if not IsDeleted(lookTarget) then lookTarget:Delete() end
          
          local qvPlace = controlledMonster:GetPlacement()
          qvPlace.vy = qvPlace.vy + controlledMonster:GetBoundingBoxSize().y + 0.01
          lookTarget = worldGlobals.MonsterControlTemplates:SpawnEntityFromTemplateByName("LookTarget",worldInfo,qvPlace)
          lookTarget:SetParent(controlledMonster,"")             
          
          localPlayer:ShowEntityInfo(lookTarget,ControllingPlayers[controlledMonster]:GetPlayerName(),"")
        
        end
      end
    end,
    
    OnEvery(CustomEvent("MonsterControl_HidePlayerNames")),
    function()
      if not IsDeleted(lookTarget) then lookTarget:Delete() end
    end  
    )
    
    if not IsDeleted(lookTarget) then lookTarget:Delete() end
     
    if not IsDeleted(controlledMonster) then
      if not worldInfo:IsSinglePlayer() and controlledMonster:IsAlive() then
        worldGlobals.MonsterControl_DropControl(controlledMonster)
      end
    end
    
    while not IsDeleted(controlledMonster) do
      if not IsMonsterBusy[controlledMonster] then 
        Wait(Delay(0.1))
        break
      end
      Wait(CustomEvent("OnStep"))
    end
    
    if not IsDeleted(controlledMonster) then
      --print("enabling 'control dropped' AI")
      controlledMonster:EnableAI()
      controlledMonster:DisableNonPlayerFoes(false)
      controlledMonster:DisablePlayerFoes(false)
      controlledMonster:FindFoe()
      ControllingPlayers[controlledMonster] = nil
      IsMonsterOwned[controlledMonster] = false
    end
 
  end)
end

--Client-side handling of the controlled monster
local ClientHandleControlledMonster = function(controlledMonster)
  RunAsync(function()
    
    if IsDeleted(controlledMonster) then return end
    
    local lookTarget
    
    IsMonsterOwned[controlledMonster] = true
    GoalPoints[controlledMonster] = nil
    
    RunHandled(function()
      Wait(Any(CustomEvent(controlledMonster,"DropControl"),Event(controlledMonster.Died)))
    end,
    
    OnEvery(CustomEvent("OnStep")),
    function()
      if IsDeleted(controlledMonster) then 
        SignalEvent(controlledMonster,"DropControl")
        return
      end
      
      if not IsMonsterBusy[controlledMonster] then
        
        controlledMonster:UnforceShootPoint() 
        
        if (GoalPoints[controlledMonster] ~= nil) then
          controlledMonster:SetGoalPoint(GoalPoints[controlledMonster])
        end
        
        if (controlledMonster:GetFoe() ~= nil) then controlledMonster:LoseFoe() end
        
      end
      
    end,
    
    OnEvery(CustomEvent("MonsterControl_ShowPlayerNames")),
    function()
      if not IsDeleted(localPlayer) then
        if worldGlobals.MonsterControl_PlayerControlEnabled[localPlayer] then
          
          if not IsDeleted(lookTarget) then lookTarget:Delete() end
          
          local qvPlace = controlledMonster:GetPlacement()
          qvPlace.vy = qvPlace.vy + controlledMonster:GetBoundingBoxSize().y + 0.01
          lookTarget = worldGlobals.MonsterControlTemplates:SpawnEntityFromTemplateByName("LookTarget",worldInfo,qvPlace)
          lookTarget:SetParent(controlledMonster,"")             
          
          localPlayer:ShowEntityInfo(lookTarget,ControllingPlayers[controlledMonster]:GetPlayerName(),"")
        
        end
      end
    end,
    
    OnEvery(CustomEvent("MonsterControl_HidePlayerNames")),
    function()
      if not IsDeleted(lookTarget) then lookTarget:Delete() end
    end    
    )
    
    if not IsDeleted(lookTarget) then lookTarget:Delete() end
    
    while not IsDeleted(controlledMonster) do
      if not IsMonsterBusy[controlledMonster] then 
        Wait(Delay(0.1))
        break
      end
      Wait(CustomEvent("OnStep"))
    end    
    
    if not IsDeleted(controlledMonster) then
      controlledMonster:UnforceShootPoint() 
      controlledMonster:LoseFoe()
      ControllingPlayers[controlledMonster] = nil
      IsMonsterOwned[controlledMonster] = false
    end
    
  end)
end

worldGlobals.CreateRPC("server","reliable","MonsterControlSetGoalPoint_Clients",function(monster,vPoint)
  if not worldGlobals.netIsHost then
    GoalPoints[monster] = vPoint
    if (vPoint == nil) then monster:StopMoving() end
  end
end)

worldGlobals.CreateRPC("client","reliable","MonsterControlSetGoalPoint",function(monster,vPoint)
  if worldGlobals.netIsHost then
    if not IsMonsterBusy[monster] then
      GoalPoints[monster] = vPoint
      if (vPoint == nil) then monster:StopMoving() end
      if not worldInfo:IsSinglePlayer() then
        worldGlobals.MonsterControlSetGoalPoint_Clients(monster,vPoint)
      end
    end
  end
end)

--Handle input of the player controlling a monster
worldGlobals.CreateRPC("client","reliable","MonsterControlHandleInput",function(player,input,vPoint,entity)
  
  if IsDeleted(player) then return end
  if IsDeleted(ControlledMonsters[player]) then return end  
  
  if player:IsLocalOperator() and not IsMonsterBusy[ControlledMonsters[player]] then
    
    RunAsync(function()
      local monsterName = ControlledMonsters[player]:GetCharacterClass()
      if (MonsterFeatures[monsterName][input] ~= nil) then
        if (MonsterFeatures[monsterName][input][1] == "shoot") then
          
          local effect
        
          local className = "None"
          if not IsDeleted(entity) then
            className = entity:GetClassName()
          end
          
          if WargablePuppetClasses[className] or EnemyPuppetClasses[className] then
            local qvPlace = entity:GetPlacement()
            qvPlace.vy = qvPlace.vy + entity:GetBoundingBoxSize().y*0.5
            effect = worldGlobals.MonsterControlTemplates:SpawnEntityFromTemplateByName("ShootTarget",worldInfo,qvPlace)
            effect:SetParent(entity,"")
          else
            local qvPlace = mthQuatVect(mthHPBToQuaternion(0,0,0),vPoint)
            effect = worldGlobals.MonsterControlTemplates:SpawnEntityFromTemplateByName("ShootTarget",worldInfo,qvPlace)
          end
          
          Wait(Delay(2.5))
          if not IsDeleted(effect) then effect:Delete() end
          
        end
      end
    end)
    
  end
  
  if worldGlobals.netIsHost then
    
    if IsDeleted(player) then return end
    if IsDeleted(ControlledMonsters[player]) then return end
    
    local monsterName = ControlledMonsters[player]:GetCharacterClass()
    if (input == "reload") then
      ControlledMonsters[player]:DropDead(0,0,0)
    elseif not IsMonsterBusy[ControlledMonsters[player]] then
      if (input == "stop") then
        worldGlobals.MonsterControlSetGoalPoint(ControlledMonsters[player],nil)
      else
        if (MonsterFeatures[monsterName][input] ~= nil) then
          worldGlobals.MonsterControlSetGoalPoint(ControlledMonsters[player],nil)
          if (MonsterFeatures[monsterName][input][1] == "shoot") then
            ShootAttack(ControlledMonsters[player],MonsterFeatures[monsterName][input],entity,vPoint)
          elseif (MonsterFeatures[monsterName][input][1] == "melee") then
            MeleeAttack(ControlledMonsters[player],MonsterFeatures[monsterName][input][2],entity,vPoint)
          elseif (MonsterFeatures[monsterName][input][1] == "jump") then
            JumpAttack(ControlledMonsters[player],MonsterFeatures[monsterName][input][2],entity,vPoint)
          elseif (MonsterFeatures[monsterName][input][1] == "suicide") then
            ControlledMonsters[player]:DropDead(0,0,0)
          end
        end
      end
    
    end
  end    
end)

--Net function for requesting control over some monster and approving it
worldGlobals.CreateRPC("server","reliable","MonsterControlSendResult",function(player,monster)
  
  if not worldGlobals.netIsHost then
    ClientHandleControlledMonster(monster)
  end

  if not IsDeleted(player) then
    ControlledMonsters[player] = monster
    if not IsDeleted(monster) then
      ControllingPlayers[monster] = player
    end   
  end
  
end)

worldGlobals.CreateRPC("client","reliable","MonsterControlRequestOwn",function(player,puppet)
  if worldGlobals.netIsHost then
    --puppet : CLeggedCharacterEntity

    if IsDeleted(puppet) then
      if not IsDeleted(ControlledMonsters[player]) then
        SignalEvent(ControlledMonsters[player],"DropControl")
      end       
      SelectedMonsters[player] = ""
      ControlledMonsters[player] = nil
      if not worldInfo:IsSinglePlayer() then
        worldGlobals.MonsterControlSendResult(player,ControlledMonsters[player])
      end
      return
    end
    
    if IsMonsterOwned[puppet] then return end
    if not puppet:IsAlive() then return end
    if (MonsterFeatures[puppet:GetCharacterClass()] == nil) then return end
    
    if not IsDeleted(ControlledMonsters[player]) then
      SignalEvent(ControlledMonsters[player],"DropControl")
    end
    
    SelectedMonsters[player] = puppet:GetCharacterClass()
    ControlledMonsters[player] = puppet
    ControllingPlayers[puppet] = player
    
    HostHandleControlledMonster(ControlledMonsters[player])
    
    if not worldInfo:IsSinglePlayer() then
      worldGlobals.MonsterControlSendResult(player,ControlledMonsters[player])
    end
    
  end
end)

--Handling puppet visual glow when controlled
local IsPuppetSelected = {}

local localPlayerWargCooldown = 0

local HandlePuppetBiases = function(puppet)
RunAsync(function()
  
  local className = puppet:GetClassName()
  if not WargablePuppetClasses[className] and not EnemyPuppetClasses[className] then return end

  local puppetOriginalBias = puppet:GetAmbientBias()
  
  while not IsDeleted(puppet) do
    
    local currentBias = puppet:GetAmbientBias()
  
    if IsMonsterOwned[puppet] then
      
      local bFriendly = true
      
      if (localPlayer ~= nil) then
        if ((worldGlobals.MonsterControl_PlayerAlignments[localPlayer] == true) and (puppet:GetAlignment() == "Good")) 
        or ((worldGlobals.MonsterControl_PlayerAlignments[localPlayer] ~= true) and (puppet:GetAlignment() == "Evil")) then
          bFriendly = false
        end
      end
      
      if (currentBias ~= controlledFriendlyBias) and bFriendly then
        puppet:SetAmbientBias(controlledFriendlyBias)
      elseif (currentBias ~= controlledEnemyBias) and not bFriendly then
        puppet:SetAmbientBias(controlledEnemyBias)
      end
    elseif IsPuppetSelected[puppet] then
      if WargablePuppetClasses[className] then
        if (MonsterFeatures[puppet:GetCharacterClass()] ~= nil) and (currentBias ~= selectedWargableBias) then
          if (localPlayerWargCooldown == 0) then
            puppet:SetAmbientBias(selectedWargableBias)
          else
            puppet:SetAmbientBias(selectedUnwargableBias)
          end
        elseif (MonsterFeatures[puppet:GetCharacterClass()] == nil) and (currentBias ~= selectedUnwargableBias) then
          puppet:SetAmbientBias(selectedUnwargableBias)
        end         
      elseif EnemyPuppetClasses[className] and (currentBias ~= selectedEnemyBias) then
        puppet:SetAmbientBias(selectedEnemyBias)
      end
    elseif (currentBias ~= puppetOriginalBias) then
      puppet:SetAmbientBias(puppetOriginalBias)
    end
    
    Wait(CustomEvent("OnStep"))
      
  end
  
end)
end

--Set information whether the player is controlling monsters or not
local SignalControlMode = function(player,bState,bAlignment)
  if player:IsLocalOperator() then
    if bState then
      SignalEvent(player,"MonsterControl_Enable",{alignment = bAlignment})
    else
      SignalEvent(player,"MonsterControl_Disable",{alignment = bAlignment})
    end
  else
    worldGlobals.MonsterControl_PlayerControlEnabled[player] = bState
    worldGlobals.MonsterControl_PlayerAlignments[player] = bAlignment
  end
end

worldGlobals.CreateRPC("server","reliable","MonsterControl_ServerSendControlMode",
function(player,bState,bAlignment)
  
  if IsDeleted(player) then return end
  SignalControlMode(player,bState,bAlignment)

end)

local PrevSpeedMultipliers = {}

worldGlobals.MonsterControl_HostSwitchPlayerControl = function(player,bState,bAlignment)
  
  if IsDeleted(player) then return end
  
  if bState then
    if bAlignment then
      player:SetAlignment("Evil")
    else
      player:SetAlignment("Good")
    end
    PrevSpeedMultipliers[player] = player:GetSpeedMultiplier()
    player:SetSpeedMultiplier(mthVector3f(0,0,0))
    player:RemoveAllWeapons()
    player:DisableWeapons()
    local AllEnemies = worldInfo:GetCharacters("","Evil",worldInfo,10000)
    for i=1,#AllEnemies,1 do
      if (AllEnemies[i]:GetFoe() == player) then AllEnemies[i]:LoseFoe() end
    end
  else
    player:SetAlignment("Good")
    player:SetSpeedMultiplier(PrevSpeedMultipliers[player])
    player:EnableWeapons()
  end
    
  if worldInfo:IsSinglePlayer() then
    SignalControlMode(player,bState,bAlignment)
  else
    worldGlobals.MonsterControl_ServerSendControlMode(player,bState,bAlignment)
  end

end

worldGlobals.CreateRPC("client","reliable","MonsterControl_ClientRequestPlayerAlignment",
function(player,bEnable,bAlignment)
  if worldGlobals.netIsHost then
    worldGlobals.MonsterControl_HostSwitchPlayerControl(player,bEnable,bAlignment)
  end
end)

--Handle local operator player
local HandleLocalPlayer = function(player)
RunAsync(function()

  local vGoalPoint
  local selectedMonster
  local controlledMonster
  local controlledMonsterEffect
  local fTargetDistance
  local fTargetDistanceMin = fTargetDistanceMinBase
  local qvTargetPos
  
  local qvCurrentPos

  local lookTargetShift
  local fLookAngle = 0
  localPlayerWargCooldown = 0
  
  local lift
  local aimTarget
  local cursorEffect
  local targetEffect
  local vPrevMouse
  local bMoveAimTarget = false
  
  local bNonExclEnabled = false
  
  local bJustEnabledMode = false
  local fHarassedTimer = 0
  
  --selectedTarget : CLeggedCharacterEntity
  local selectedTarget
  local selectedOriginalBias
  local selectedMonsterEffect
  local controlledOriginalBias
  local aimedPoint
 
  local strMonsterControlsInfoString = ""
  
  local bShowingNames = false
  local bPlayerChatting = false

  RunAsync(function()
    Wait(CustomEvent("OnStep"))
  end)
  
  RunHandled(function()
    while not IsDeleted(player) do
      local step = Wait(CustomEvent("OnStep")):GetTimeStep()
      localPlayerWargCooldown = mthMaxF(0,localPlayerWargCooldown - step)
    end
  end,
  
  OnEvery(Delay(0.2)),
  function()
    if not IsDeleted(lift) then
      lift:SetStretch(worldGlobals.MonsterControlFOV/90)
    end
  end,
  
  OnEvery(CustomEvent(player,"MonsterControl_Enable")),
  function(pay)
    if worldInfo:GetCurrentChapter() then
      qvTargetPos = worldInfo:GetCurrentChapter():GetPlacement()
    else
      qvTargetPos = player:GetPlacement()
    end
    bJustEnabledMode = true
    fTargetDistance = fTargetDistanceBase
    qvCurrentPos = mthCloneQuatVect(qvTargetPos)
    qvCurrentPos:SetVect(qvCurrentPos:GetVect() - lookTargetShiftBase*fTargetDistance)
    lookTargetShift = mthCloneVector3f(lookTargetShiftBase)
    vPrevMouse = worldInfo:GetMousePosition()
    bMoveAimTarget = false
    worldInfo:AddLocalTextEffect(ControlsTFX,"Switch to First-Person and press 'Crouch'\nto enable mouse input mode\nUse movement keys to move camera\nPress 'Reload' to reset camera")
    worldGlobals.MonsterControl_PlayerControlEnabled[player] = true
    worldGlobals.MonsterControl_PlayerAlignments[player] = pay.alignment
  end,
  
  OnEvery(CustomEvent(player,"MonsterControl_Disable")),
  function(pay)
    if not IsDeleted(lift) then lift:Delete() end
    local qvReturn
    if worldInfo:GetCurrentChapter() then
      qvReturn = worldInfo:GetCurrentChapter():GetPlacement()
    elseif (#worldInfo:GetAllEntitiesOfClass("CSpawnMarkerEntity") > 0) then
      local AllMarkers = worldInfo:GetAllEntitiesOfClass("CSpawnMarkerEntity")
      qvReturn = AllMarkers[mthRndRangeL(1,#AllMarkers)]:GetPlacement()
    else
      qvReturn = worldInfo:GetClosestPlayer(worldInfo,10000):GetPlacement()
    end            
    player:SetPlacement(qvReturn)
    if not IsDeleted(aimTarget) then aimTarget:Delete() end
    if not IsDeleted(controlledMonsterEffect) then
      controlledMonsterEffect:Delete()
    end
    if not IsDeleted(selectedTarget) then 
      IsPuppetSelected[selectedTarget] = false 
    end
    selectedTarget = nil
    --controlledMonster = nil  
    worldGlobals.MonsterControlRequestOwn(player,nil)
    worldGlobals.MonsterControl_PlayerControlEnabled[player] = false
    worldGlobals.MonsterControl_PlayerAlignments[player] = pay.alignment
    bNonExclEnabled = false
    worldInfo:AddLocalTextEffect(ControlsTFX,"")
    worldInfo:AddLocalTextEffect(MonsterInfoTFX,"")
    worldInfo:SetNonExclusiveInput(bNonExclEnabled)      
  end,  
  
  OnEvery(CustomEvent("XML_Log")),
  function(LogEvent)
    local line = LogEvent:GetLine()
    if not IsDeleted(player) then
      if (string.find(line, "<chat player=\""..player:GetPlayerName().."\" playerid=\""..player:GetPlayerId()) ~= nil) then
        bPlayerChatting = false
      end
    end
  end,
  
  OnEvery(CustomEvent("OnStep")),
  function()
    
    if IsDeleted(player) then return end
    
    --On each frame, process player inputs
    if player:IsCommandPressed("plcmdTalk") and not bPlayerChatting then
      bPlayerChatting = true    
    elseif (IsKeyPressed("Escape") or IsKeyPressed("Enter")) and bPlayerChatting then
      bPlayerChatting = false    
    end

    if player:IsCommandPressed("plcmdThirdPersonView") and not bPlayerChatting and worldGlobals.MonsterControl_PlayerControlEnabled[player] then
      SignalEvent("MonsterControl_ShowPlayerNames")
      bShowingNames = true
    elseif (player:GetCommandValue("plcmdThirdPersonView") < 1) and bShowingNames then
      SignalEvent("MonsterControl_HidePlayerNames")
      bShowingNames = false
    end    
  
    if not worldGlobals.MonsterControl_PlayerControlEnabled[player] then return end
    
    if bJustEnabledMode then
      bJustEnabledMode = false
    else
      if (mthLenV3f(qvCurrentPos:GetVect() - player:GetPlacement():GetVect()) > 20) then
        worldInfo:AddLocalTextEffect(WarningTFX,"You got into an out-of-bounds teleporter!\nMove around or change camera distance to get out of it!")
        fHarassedTimer = 0
      else
        fHarassedTimer = fHarassedTimer + worldInfo:SimGetStep()
        if (fHarassedTimer > 0.2) then
          worldInfo:AddLocalTextEffect(WarningTFX,"")
        end
      end
    end
    
    if player:IsCommandPressed("plcmdY-") and not bPlayerChatting then
      
      bNonExclEnabled = not bNonExclEnabled
      if bNonExclEnabled then
        worldInfo:AddLocalTextEffect(ControlsTFX,"'Crouch' - exit mouse input, 'Use' - warg into monster\nMovement keys/mouse wheel - move/rotate camera\n'Next/Prev weapon' - change camera distance\n'Alt-Fire' - set camera target, 'Reload' - reset camera")
      else
        worldInfo:AddLocalTextEffect(ControlsTFX,"Switch to First-Person and press 'Crouch'\nto enable mouse input mode\nPress 'Reload' to reset camera")
        if not worldGlobals.MonsterControl_BlockManualWarging then
          worldGlobals.MonsterControlRequestOwn(player,nil)
        end
      end      
      worldInfo:SetNonExclusiveInput(bNonExclEnabled)  
      
    end
    
    --CAMERA DISTANCE
    if player:IsCommandPressed("plcmdPrevWeapon") and not bPlayerChatting and (fTargetDistance < fTargetDistanceMax) then
      fTargetDistance = fTargetDistance*fTargetDistanceStepMultiplier
    end
    if player:IsCommandPressed("plcmdNextWeapon") and not bPlayerChatting and (fTargetDistance > fTargetDistanceMin) then
      fTargetDistance = fTargetDistance/fTargetDistanceStepMultiplier
    end
    
    --CAMERA ROTATION
    local vMouse = worldInfo:GetMousePosition()
    if not worldInfo:IsInputNonExclusive() then vMouse = mthVector3f(100000,0,100000) end
    if IsKeyPressed("Mouse Button 3") then
    
      fLookAngle = fLookAngle + fCameraRotationPerScreen*(vMouse.x - vPrevMouse.x)/GetGameScreenWidth()
      lookTargetShift = mthQuaternionToDirection(mthMulQ4f(mthHPBToQuaternion(fLookAngle,0,0),mthDirectionToQuaternion(lookTargetShiftBase)))
    
    end
    vPrevMouse = mthCloneVector3f(vMouse)
    
    --CONTROLLED MONSTER CHANGE
    if (ControlledMonsters[player] ~= controlledMonster) then

      controlledMonster = ControlledMonsters[player]  
      worldGlobals.MonsterControl_LocalControlledMonster = controlledMonster
      
      if not IsDeleted(controlledMonster) then
        
        fTargetDistanceMin = controlledMonster:GetBoundingBoxSize().y/2 + 2
        if (fTargetDistance < fTargetDistanceMin) then fTargetDistance = fTargetDistanceMin end
        worldInfo:AddLocalTextEffect(ControlsTFX,"'Crouch' - exit mouse input, 'Use' - change/leave monster\nMovement keys/mouse wheel - move/rotate camera\n'Next/Prev weapon' - change camera distance")
      
        RunAsync(function()
          --wargSound : CStaticSoundEntity
          local wargSound = worldGlobals.MonsterControlTemplates:SpawnEntityFromTemplateByName("WargInSound",worldInfo,player:GetPlacement())
          Wait(wargSound:PlayOnceWait(0,0))
          if not IsDeleted(wargSound) then wargSound:Delete() end
        end)
      
        local Features = MonsterFeatures[controlledMonster:GetCharacterClass()]
        strMonsterControlsInfoString = "'Fire' - walk, 'Sprint' - stop, 'Reload' - suicide\n"
        for _,command in pairs(AvalilableInputs) do
          if (Features[command] ~= nil) then
            strMonsterControlsInfoString = strMonsterControlsInfoString.."'"..CommandToText[command].."' - "
            if (Features[command][1] == "shoot") then
              strMonsterControlsInfoString = strMonsterControlsInfoString.."shoot attack '"..Features[command][2].."'x"..Features[command][3].."\n"
            elseif (Features[command][1] == "melee") then
              strMonsterControlsInfoString = strMonsterControlsInfoString.."melee attack '"..Features[command][2].."'\n"
            elseif (Features[command][1] == "jump") then
              strMonsterControlsInfoString = strMonsterControlsInfoString.."jump attack '"..Features[command][2].."'\n"
            elseif (Features[command][1] == "suicide") then
              strMonsterControlsInfoString = strMonsterControlsInfoString.."suicide\n"
            end
          end
        end
        --worldInfo:AddLocalTextEffect(MonsterInfoTFX,string)
      
        if not IsDeleted(aimTarget) then
          aimTarget:SetParent(controlledMonster,"")
          bMoveAimTarget = true
        end        
        
        if IsDeleted(controlledMonsterEffect) then
          if (worldInfo:GetGameMode() == "ControlManHunt") then
            controlledMonsterEffect = worldGlobals.MonsterControlTemplates:SpawnEntityFromTemplateByName("ControlledMonsterManhunt",worldInfo,controlledMonster:GetPlacement())
          else
            controlledMonsterEffect = worldGlobals.MonsterControlTemplates:SpawnEntityFromTemplateByName("ControlledMonster",worldInfo,controlledMonster:GetPlacement())
          end
          controlledMonsterEffect:SetParent(controlledMonster,"")
        end
        
        controlledMonsterEffect:SetPlacement(controlledMonster:GetPlacement())
        controlledMonsterEffect:SetParent(controlledMonster,"")
        local vBBox = controlledMonster:GetBoundingBoxSize()
        vBBox.y = 0
        controlledMonsterEffect:SetStretch(mthMaxF(mthLenV3f(vBBox)*0.5,1))        
        
      else
      
        fTargetDistanceMin = fTargetDistanceMinBase
        if (fTargetDistance < fTargetDistanceMin) then fTargetDistance = fTargetDistanceMin end        
        
        worldInfo:AddLocalTextEffect(ControlsTFX,"'Crouch' - exit mouse input, 'Use' - warg into monster\nMovement keys/mouse wheel - move/rotate camera\n'Next/Prev weapon' - change camera distance\n'Alt-Fire' - set camera target, 'Reload' - reset camera")      
        worldInfo:AddLocalTextEffect(MonsterInfoTFX,"")
        
        if not IsDeleted(controlledMonsterEffect) then
          controlledMonsterEffect:Delete()
        end        
      
      end     
    end
    
    --HANDLING CONTROLLED MONSTER BEING DELETED
    if not IsDeleted(controlledMonster) then
      if not controlledMonster:IsAlive() then
        ControlledMonsters[player] = nil
        --controlledMonster = nil
        if not IsDeleted(controlledMonsterEffect) then
          controlledMonsterEffect:Delete()
        end        
      end
    end
    
    --CAMERA FOLLOWING THE MONSTER
    if not IsDeleted(controlledMonster) then
      if (qvTargetPos.qp ~= 0) then
        bMoveAimTarget = true
      end
      if (qvTargetPos.qb ~= 0) then
        bMoveAimTarget = true
      end      
      qvTargetPos = controlledMonster:GetPlacement()
      qvTargetPos.vy = qvTargetPos.vy + controlledMonster:GetBoundingBoxSize().y/2
    else  
      local fRealMoveSpeed = fCameraMoveSpeed * (fTargetDistance)/40
      local vShiftVector = mthVector3f((player:GetCommandValue("plcmdX+")-player:GetCommandValue("plcmdX-"))*worldInfo:SimGetStep()*fRealMoveSpeed,0,(player:GetCommandValue("plcmdZ+")-player:GetCommandValue("plcmdZ-"))*worldInfo:SimGetStep()*fRealMoveSpeed)
      if bPlayerChatting then vShiftVector = mthVector3f(0,0,0) end
      local fShiftLen = mthLenV3f(vShiftVector)
      vShiftVector = fShiftLen*mthQuaternionToDirection(mthMulQ4f(mthHPBToQuaternion(fLookAngle,0,0),mthDirectionToQuaternion(mthNormalize(vShiftVector))))
      qvTargetPos:SetVect(qvTargetPos:GetVect() + vShiftVector) 
    end
    
    qvCurrentPos:SetVect(qvTargetPos:GetVect() - lookTargetShift*fTargetDistance)
    local origin = qvCurrentPos:GetVect() + player:GetLookOrigin():GetVect() - player:GetPlacement():GetVect()
    local lookDir = player:GetLookOrigin():GetQuat()  
    
    if bMoveAimTarget and not IsDeleted(aimTarget) then
      aimTarget:SetPlacement(qvTargetPos)
      bMoveAimTarget = false
    end 
    
    --MOUSE POINTING CALCULATION FOR CURSOR VISUALS 
    local stretch = mthTanF(worldGlobals.MonsterControlFOV/360*Pi) * 9/16
    local boxSize = mthVector3f(2*stretch/9*16,2*stretch,0)    
    local dirZ = mthQuaternionToDirection(lookDir)
    local qvZ = mthQuatVect(lookDir,mthVector3f(0,0,0))
    local ZrotX = mthQuatVect(mthHPBToQuaternion(-Pi/2,0,0),mthVector3f(0,0,0))
    local dirX = mthQuaternionToDirection(mthMulQV(qvZ,ZrotX):GetQuat())*boxSize.x
    local dirY = mthNormalize(mthCrossV3f(dirZ,dirX))*boxSize.y
  
    local qvPlace = mthQuatVect(qNull,origin+(dirZ-dirX/2-dirY/2 + dirX*vMouse.x/GetGameScreenWidth() + dirY*vMouse.y/GetGameScreenHeight())*400)  
    
    if IsDeleted(cursorEffect) then
      cursorEffect = worldGlobals.MonsterControlTemplates:SpawnEntityFromTemplateByName("Cursor",worldInfo,qvPlace)
    else
      cursorEffect:SetPlacement(qvPlace)
    end
   
    if not IsDeleted(selectedTarget) then
      if not selectedTarget:IsAlive() then
        IsPuppetSelected[selectedTarget] = false
        selectedTarget = nil
      end
    end
    
    --SELECTION CHECK    
    local enHitEntity,vHitPoint,vHitNormal = CastRayToMouse(player,"bullet")
        
    local width = 0.1
    local enHitEntityNS,vHitPointNS,vHitNormalNS = CastRayToMouse(player,"bullet_no_solids",width*fTargetDistance/100)
    while ((mthLenV3f(vHitPoint-player:GetPlacement():GetVect()) < mthLenV3f(vHitPointNS-player:GetPlacement():GetVect())) or (enHitEntityNS == nil)) and (width < 2.1) do
      width = width + 0.5
      enHitEntityNS,vHitPointNS,vHitNormalNS = CastRayToMouse(player,"bullet_no_solids",width*fTargetDistance/100)
    end
    
    if (enHitEntityNS == controlledMonster) then enHitEntityNS = nil end
    if not IsDeleted(enHitEntityNS) then
      if IsMonsterOwned[enHitEntityNS] then enHitEntityNS = nil end
    end
    
    if (enHitEntity ~= nil) or (enHitEntityNS ~= nil) then
      if (enHitEntity == nil) or ((mthLenV3f(vHitPoint-player:GetPlacement():GetVect()) > mthLenV3f(vHitPointNS-player:GetPlacement():GetVect())) and (enHitEntityNS ~= nil)) then
        if (selectedTarget ~= enHitEntityNS) then
        
          if not IsDeleted(selectedTarget) then IsPuppetSelected[selectedTarget] = false end
          
          local className = enHitEntityNS:GetClassName()
          
          if WargablePuppetClasses[className] or EnemyPuppetClasses[className] then
          
            selectedTarget = enHitEntityNS
            IsPuppetSelected[selectedTarget] = true
          
          end
          
        end
        
      else
        
        if not IsDeleted(selectedTarget) then IsPuppetSelected[selectedTarget] = false end
        selectedTarget = nil
        
      end
    else
      if not IsDeleted(selectedTarget) then IsPuppetSelected[selectedTarget] = false end
      selectedTarget = nil    
    end
    
    --TAKING CONTROL OVER THE MONSTER
    if player:IsCommandPressed("plcmdUse") and not bPlayerChatting and not worldGlobals.MonsterControl_BlockManualWarging then
      if IsDeleted(selectedTarget) then
        worldGlobals.MonsterControlRequestOwn(player,selectedTarget)
      elseif WargablePuppetClasses[selectedTarget:GetClassName()] and (localPlayerWargCooldown == 0) then
        localPlayerWargCooldown = fWargInCooldown
        worldGlobals.MonsterControlRequestOwn(player,selectedTarget)
      end
    end      
  
    --IF HAS CONTROLLED MONSTER, PRINT INFO AND HANDLE CONTROLS
    if not IsDeleted(controlledMonster) then
    
      local string = controlledMonster:GetCharacterClass().."\n"..strMonsterControlsInfoString
      worldInfo:AddLocalTextEffect(MonsterInfoTFX, string)
    
      if player:IsCommandPressed("plcmdFire") and not bPlayerChatting and not IsMonsterBusy[controlledMonster] then        
        local enHitEntity,vHitPoint,vHitNormal = CastRayToMouse(player,"character_only_solids")
        if (vHitPoint ~= nil) then   
          worldGlobals.MonsterControlSetGoalPoint(controlledMonster,vHitPoint)
          
          if not IsDeleted(targetEffect) then targetEffect:Delete() end
          
          targetEffect = worldGlobals.MonsterControlTemplates:SpawnEntityFromTemplateByName("TargetPoint",worldInfo,mthQuatVect(qNull,vHitPoint))
          local vBBox = controlledMonster:GetBoundingBoxSize()
          vBBox.y = 0
          targetEffect:SetStretch(mthMaxF(mthLenV3f(vBBox)*0.5,1))
          RunAsync(function()
            local oldEffect = targetEffect
            Wait(Delay(1.2))
            if not IsDeleted(oldEffect) then 
              oldEffect:Delete()
            end
          end)
                  
        end
      end
      
      if player:IsCommandPressed("plcmdSprint") and not bPlayerChatting then
        if not IsDeleted(targetEffect) then targetEffect:Delete() end
        worldGlobals.MonsterControlHandleInput(player,"stop",nil,nil)
      end
      
      if (player:IsCommandPressed("plcmdReload") or player:IsCommandPressed("plcmdAltFire") or (player:IsCommandPressed("plcmdFire") and (player:GetCommandValue("plcmdSprint") > 0)) or player:IsCommandPressed("plcmdY+")) and not bPlayerChatting then
        if not IsDeleted(targetEffect) then targetEffect:Delete() end
        local enHitEntity,vHitPoint,vHitNormal = CastRayToMouse(player,"bullet")
        
        local width = 0.1
        local enHitEntityNS,vHitPointNS,vHitNormalNS = CastRayToMouse(player,"bullet_no_solids",width*fTargetDistance/100)
        while ((mthLenV3f(vHitPoint-player:GetPlacement():GetVect()) < mthLenV3f(vHitPointNS-player:GetPlacement():GetVect())) or (enHitEntityNS == nil)) and (width < 2.1) do
          width = width + 0.5
          enHitEntityNS,vHitPointNS,vHitNormalNS = CastRayToMouse(player,"bullet_no_solids",width*fTargetDistance/100)
        end
        
        if (enHitEntity ~= nil) or (enHitEntityNS ~= nil) then
          
          local entity = enHitEntity
          local point = vHitPoint
        
          if (enHitEntity == nil) or ((mthLenV3f(vHitPoint-player:GetPlacement():GetVect()) > mthLenV3f(vHitPointNS-player:GetPlacement():GetVect())) and (enHitEntityNS ~= nil)) then
            entity = enHitEntityNS
            point = vHitPointNS            
          else
            entity = enHitEntity
            point = vHitPoint          
          end
          
          local bCancelCommand = false
          
          if not IsDeleted(entity) then
            
            if not WargablePuppetClasses[entity:GetClassName()] and not EnemyPuppetClasses[entity:GetClassName()] then 
              entity = nil
            else
              if worldGlobals.MonsterControl_PlayerControlEnabled[entity] then bCancelCommand = true end
            end

          end
          
          if not bCancelCommand then
            if player:IsCommandPressed("plcmdAltFire") then
              if (player:GetCommandValue("plcmdSprint") > 0) then
                worldGlobals.MonsterControlHandleInput(player,"shiftAltFire",point,entity) 
              else
                worldGlobals.MonsterControlHandleInput(player,"altFire",point,entity) 
              end
            elseif player:IsCommandPressed("plcmdFire") then
              if (player:GetCommandValue("plcmdSprint") > 0) then
                worldGlobals.MonsterControlHandleInput(player,"shiftFire",point,entity) 
              end
            elseif player:IsCommandPressed("plcmdY+") then
              worldGlobals.MonsterControlHandleInput(player,"jump",point,entity)
            elseif player:IsCommandPressed("plcmdReload") then
              worldGlobals.MonsterControlHandleInput(player,"reload",point,entity)                  
            end  
          end        
          
        end
      end  
      
    else
    
      if player:IsCommandPressed("plcmdAltFire") and not bPlayerChatting then
        if (mthLenV3f(vHitPoint) ~= 0) then
          qvTargetPos:SetVect(vHitPoint)
        end
      end
      
      if player:IsCommandPressed("plcmdReload") and not bPlayerChatting then
        if (worldInfo:GetCurrentChapter() ~= nil) then
          qvTargetPos = worldInfo:GetCurrentChapter():GetPlacement()
        else
          qvTargetPos = worldInfo:GetPlacement()
        end
      end      
      
      if not IsDeleted(aimTarget) then
        aimTarget:SetPlacement(qvTargetPos)
      end
      
    end
    
    if IsDeleted(lift) then
      lift = worldGlobals.MonsterControlTemplates:SpawnEntityFromTemplateByName("Lift",worldInfo,qvCurrentPos)
    end
    lift:SetPlacement(qvCurrentPos)
    qvCurrentPos:SetQuat(mthDirectionToQuaternion(mthNormalize(qvTargetPos:GetVect() - qvCurrentPos:GetVect())))     
    qvCurrentPos.qb = 0
    player:SetPlacement(qvCurrentPos)
    qvCurrentPos:SetQuat(qNull)
    
    worldGlobals.MonsterControl_LocalCurrentPos = qvCurrentPos
    
    if IsDeleted(aimTarget) then
      aimTarget = worldGlobals.MonsterControlTemplates:SpawnEntityFromTemplateByName("LookTarget",worldInfo,qvTargetPos)
      if not IsDeleted(controlledMonster) then
        aimTarget:SetParent(controlledMonster,"")
      end
      worldGlobals.MonsterControl_AimTarget = aimTarget
      player:SetLookTarget(aimTarget)
    end    
    
  end)
  
  if not IsDeleted(selectedTarget) then IsPuppetSelected[selectedTarget] = false end
  
end)
end


--Handle other players in general
local HandlePlayer = function(player)
  RunAsync(function()
    
    local lift
    local lookTarget
    
    RunHandled(function()
      while not IsDeleted(player) do
        if worldGlobals.MonsterControl_PlayerControlEnabled[player] then
          
          if IsDeleted(lift) then
            lift = worldGlobals.MonsterControlTemplates:SpawnEntityFromTemplateByName("Lift",worldInfo,player:GetPlacement())
          end
          player:SetLinearVelocity(mthVector3f(0,0,0))
          lift:SetPlacement(player:GetPlacement())
          
        else
        
          if not IsDeleted(lift) then lift:Delete() end  
        
        end
        Wait(CustomEvent("OnStep"))
      end
    end,
    
    OnEvery(Delay(0.2)),
    function()
      if not IsDeleted(lift) then
        lift:SetStretch(worldGlobals.MonsterControlFOV/90)
      end
    end,  
    
    OnEvery(CustomEvent("MonsterControl_ShowPlayerNames")),
    function()
      if not IsDeleted(localPlayer) then
        if worldGlobals.MonsterControl_PlayerControlEnabled[localPlayer] then
          
          if not IsDeleted(lookTarget) then lookTarget:Delete() end
          
          local qvPlace = player:GetPlacement()
          qvPlace.vy = qvPlace.vy + player:GetBoundingBoxSize().y + 0.01
          lookTarget = worldGlobals.MonsterControlTemplates:SpawnEntityFromTemplateByName("LookTarget",worldInfo,qvPlace)
          lookTarget:SetParent(player,"")             
          
          localPlayer:ShowEntityInfo(lookTarget,player:GetPlayerName(),"")
          
        end
      end
    end,
     
    OnEvery(CustomEvent("MonsterControl_HidePlayerNames")),
    function()
      if not IsDeleted(lookTarget) then lookTarget:Delete() end
    end)
      
    if not IsDeleted(lookTarget) then lookTarget:Delete() end
    if not IsDeleted(lift) then lift:Delete() end
    
  end)
end

local IsHandled = {}
local IsBiasHandled = {}

RunHandled(WaitForever,

OnEvery(Delay(0.2)),
function()
  string = prjGetCustomOccasion()
  local config = string.match(string, "{FOVforCWM=.-}")
  if not (config == nil) then
    local arg = string.sub(config,12,-2)
    if not (arg == "") then
      worldGlobals.MonsterControlFOV = tonumber(arg)
      if (worldGlobals.MonsterControlFOV == -1) then
        if worldGlobals.NSKuberIsBFE then
          worldGlobals.MonsterControlFOV = 75
        else
          worldGlobals.MonsterControlFOV = 90
        end
      end
    end
  end
  
  local Characters = worldInfo:GetCharacters("","",worldInfo,10000)
  for i=1,#Characters,1 do
    if not IsBiasHandled[Characters[i]] then
      IsBiasHandled[Characters[i]] = true
      HandlePuppetBiases(Characters[i])
    end
  end  
  
end,

OnEvery(CustomEvent("OnStep")),
function()
  local Players = worldInfo:GetAllPlayersInRange(worldInfo,10000)
  for i=1,#Players,1 do
    if not IsHandled[Players[i]] then
      IsHandled[Players[i]] = true
      if Players[i]:IsLocalOperator() then
        HandleLocalPlayer(Players[i])
        localPlayer = Players[i]
      else
        HandlePlayer(Players[i])
      end
    end
  end
    
end)