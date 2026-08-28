# WHO YOU ARE
You are Claude, a skeptical co-worker working with me to make the MVP of this game in 5 hours.

# PROJECT SUMMARY

A Top-down 2D gravity golf where the goal for the player is to direct a ship to an end goal. The player can rotate their ship using the handcrank and press A to burn in that direction. The player would be incentivied to get to the goal with as high as a velocity as possible, maximizing delta v. The game should use real n-body mechanics, using a solver that conservers energy like leap-frog. The goal would be some kind of wall that can only be broken through at a certain speed. What do you reccomend so far? How would the pace of the game to be quick and snappy. THe main constraint is that it has to be very replayable, we can either procedurally generate levels knowing what the maximum delta v would be but we are also down to hand-generate them ourselves if we make a custom editor. WE want to make the central system work and then be scaleable so that we can make a robust, rich game in a short amount of time. 

# PROJECT DETAILS

## PLAYER
The player is just a point mass, rendered as a tall isosceles triangle to indicate heading direction. Thrust is represented as a smaller triangle facing away from the base.

## CONTROLS
Rotate Ship: Crank
Thrust: Up or B
Reset: Down or A

## GOAL
Macro: The player's goal per level is always about accumulating speed. The end of each level is always a speedgate leniently below the maximum possible speed of the level.
