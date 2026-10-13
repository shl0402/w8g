"""Native multi-stop job contract, using a temporary DB and fake routing engine."""
import json
from datetime import datetime, timedelta
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from server import routing, storage, cloud


class MultiStopJobs(unittest.TestCase):
	def setUp(self):
		self.tmp = tempfile.TemporaryDirectory()
		self.addCleanup(self.tmp.cleanup)
		p = patch.object(storage, 'DB', Path(self.tmp.name) / 'jobs.sqlite3')
		p.start(); self.addCleanup(p.stop)
		p = patch.object(cloud, 'ENABLED', False)
		p.start(); self.addCleanup(p.stop)
		storage.init()
		self.places = [dict(name=n, lat=22.28, lon=114.15+i/100) for i,n in enumerate(['Central','Admiralty','Wan Chai'])]
		self.departure = '2026-10-02T10:00:00+08:00'
		self.payload = dict(stops=self.places, departure=self.departure, modes=[], preference='fastest', channel='explore', order='ordered')
		with storage.db() as db:
			db.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?,?,?,?)', ('job','owner','request','queued',json.dumps(self.payload),None,None,'',0))

	def route(self, request):
		start = datetime.fromisoformat(request['departure'])
		end = start + timedelta(minutes=5)
		leg = dict(mode='WALK',transitLeg=False,duration=300,distance=350,
			start={'scheduledTime':start.isoformat()},end={'scheduledTime':end.isoformat()},
			**{'from':request['origin'],'to':request['destination']})
		return dict(legs=[leg],start=start.isoformat(),end=end.isoformat(),duration=300,displayDurationSeconds=300,walkDistance=350,transfers=0)

	def window(self):
		return (datetime.fromisoformat(self.departure),datetime.fromisoformat(self.departure)+timedelta(days=2))

	def test_ordered_visits_advance_the_departure_and_return_a_saveable_journey(self):
		requests=[]
		def plan(request):
			requests.append(request)
			return dict(itineraries=[self.route(request)],warnings=[])
		with patch.object(routing.router,'plan',side_effect=plan), patch.object(routing.router,'service_window',side_effect=self.window):
			routing.run('job',self.payload)
		job=routing.job('owner','job')
		self.assertEqual(job['state'],'succeeded',job.get('error'))
		self.assertEqual(requests[1]['departure'],'2026-10-02T10:05:00+08:00')
		journey=job['routes'][0]
		self.assertEqual(journey['stops'],self.places)
		self.assertEqual(journey['duration'],600)
		self.assertEqual(journey['walkDistance'],700)
		self.assertEqual(journey['end'],'2026-10-02T10:10:00+08:00')
		self.assertEqual([(t['legStartIndex'],t['legEndIndex']) for t in journey['trips']],[(0,1),(1,2)])
		self.assertEqual([t['duration'] for t in journey['trips']],[300,300])
		self.assertEqual(journey['trips'][1]['start'],'2026-10-02T10:05:00+08:00')
		with self.assertRaises(KeyError):routing.job('another-user','job')

	def test_optimised_response_preserves_solver_order_and_includes_all_legs(self):
		order=[2,0,1];events=[];cursor=self.departure
		for index,i in enumerate(order):
			events.append(dict(kind='job',jobId=str(i),seconds=0))
			if index<2:
				it=self.route(dict(departure=cursor,origin=self.places[i],destination=self.places[order[index+1]]))
				events.append(dict(kind='travel',seconds=300,itinerary=it));cursor=it['end']
		state=dict(status='succeeded',events=[],result=dict(feasible=True,schedules=[dict(events=events,finish=cursor)]))
		with patch.object(routing,'manager') as manager, patch.object(routing.router,'service_window',side_effect=self.window):
			manager.start.return_value={'id':'optimised'};manager.get.return_value=state
			routing.run('job',dict(self.payload,order='optimise'))
		journey=routing.job('owner','job')['routes'][0]
		self.assertEqual(journey['stops'],[self.places[i] for i in order])
		self.assertEqual(len(journey['legs']),2)
		self.assertEqual(journey['duration'],600)
		self.assertIn('free start/end',journey['optimisationNote'])
		self.assertEqual(len(journey['trips']),2)
		for index,trip in enumerate(journey['trips']):
			part=journey['legs'][trip['legStartIndex']:trip['legEndIndex']]
			self.assertEqual(part[0]['from'],self.places[order[index]])
			self.assertEqual(part[-1]['to'],self.places[order[index+1]])


	def test_default_and_override_shift_the_next_trip(self):
		for override,expected in [(None,15),(0,0),(7,7)]:
			requests=[]
			def plan(request):
				requests.append(request)
				return dict(itineraries=[self.route(request)],warnings=[])
			payload=dict(self.payload,defaultStayMinutes=15,stopStayMinutes=[0,override,0])
			with patch.object(routing.router,'plan',side_effect=plan), patch.object(routing.router,'service_window',side_effect=self.window):
				routing.run('job',payload)
			journey=routing.job('owner','job')['routes'][0]
			self.assertEqual(requests[1]['departure'],(datetime.fromisoformat(self.departure)+timedelta(minutes=5+expected)).isoformat())
			self.assertEqual(journey['duration'],600+expected*60)
			self.assertEqual(journey['stopStayMinutes'],[0,expected,0])
			self.assertEqual(journey['trips'][1]['departure'],requests[1]['departure'])

	def test_stay_validation_and_backward_compatibility(self):
		self.assertEqual(routing.stop_stays(self.payload),[0,0,0])
		self.assertEqual(routing.stop_stays(dict(self.payload,defaultStayMinutes=20)),[0,20,0])
		for value in [-1,721,True,1.5,'10']:
			with self.assertRaises(ValueError):routing.stop_stays(dict(self.payload,defaultStayMinutes=value))
			with self.assertRaises(ValueError):routing.stop_stays(dict(self.payload,stopStayMinutes=[0,value,0]))
		for value in [[],[10], 'invalid']:
			with self.assertRaises(ValueError):routing.stop_stays(dict(self.payload,stopStayMinutes=value))
		with patch.object(routing.router,'validate_request'):
			clean=routing.validate(dict(self.payload,defaultStayMinutes=15,stopStayMinutes=[0,7,0]))
		self.assertEqual(clean['defaultStayMinutes'],15)
		self.assertEqual(clean['stopStayMinutes'],[0,7,0])

	def test_optimised_stays_follow_places_including_final_visit(self):
		# Solver moves the added destination to the end; its stay must still count.
		order=[2,0,1];events=[];cursor=datetime.fromisoformat(self.departure)
		for index,i in enumerate(order):
			minutes=12 if i==1 else 0
			events.append(dict(kind='job',jobId=str(i),seconds=minutes*60))
			cursor+=timedelta(minutes=minutes)
			if index<2:
				it=self.route(dict(departure=cursor.isoformat(),origin=self.places[i],destination=self.places[order[index+1]]))
				events.append(dict(kind='travel',start=cursor.isoformat(),seconds=300,itinerary=it))
				cursor=datetime.fromisoformat(it['end'])
		state=dict(status='succeeded',events=[],result=dict(feasible=True,schedules=[dict(events=events,finish=cursor.isoformat())]))
		with patch.object(routing,'manager') as manager,patch.object(routing.router,'service_window',side_effect=self.window):
			manager.start.return_value={'id':'optimised'};manager.get.return_value=state
			routing.run('job',dict(self.payload,order='optimise',defaultStayMinutes=12))
			self.assertEqual([j['serviceMinutes'] for j in manager.start.call_args.args[0]['jobs']],[0,12,0])
		journey=routing.job('owner','job')['routes'][0]
		self.assertEqual(journey['stopStayMinutes'],[0,0,12])
		self.assertEqual(journey['duration'],22*60)
		self.assertEqual(journey['end'],'2026-10-02T10:22:00+08:00')


if __name__ == '__main__':unittest.main()
